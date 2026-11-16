import Foundation
import Testing
import CursusCore
@testable import CursusVox

private final class TransformFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var finish = "stop"
    nonisolated(unsafe) static var http = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": Self.finish,
            "message": ["content": "Bonjour\nSam"]]], "usage": ["cost": 0.003]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.http, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct TextTransformTests {
    @Test func privateRequestSeparatesInstructionAndSource() throws {
        let source = "Please send a message to someone."
        let body = try #require(TextTransform.body(model: "fixture/model", command: .translate("French"), source: source))
        #expect((body["provider"] as? [String: String])?["data_collection"] == "deny")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[1]["content"] == source)
        #expect(messages[0]["content"]?.contains("Translate") == true)
        #expect(TextTransform.body(model: "fixture/model", command: .search("x"), source: source) == nil)
    }
    @Test func failedUsageAdmissionNeverStartsTransport() async {
        TransformFixture.requests = 0
        await #expect(throws: (any Error).self) {
            _ = try await TextTransform(protocolClasses: [TransformFixture.self]).run(command: .rewrite(.concise), source: "Original", model: "fixture/model", key: "synthetic-fixture", admit: { _ in false }, record: { _ in })
        }
        #expect(TransformFixture.requests == 0)
    }
    @Test func successAndUnusableResponsesRetainActualCharges() async throws {
        for (status, finish, expected) in [(200,"stop",UsageEvent.Outcome.succeeded), (200,"length",.rejected), (503,"stop",.failed)] {
            TransformFixture.requests = 0; TransformFixture.http = status; TransformFixture.finish = finish
            var events: [UsageEvent] = []
            do {
                let reply = try await TextTransform(protocolClasses: [TransformFixture.self]).run(command: .translate("French"), source: "Hello\nSam", model: "fixture/model", key: "synthetic-fixture", admit: { event in events.append(event); return true }, record: { events.append($0) })
                #expect(expected == .succeeded)
                #expect(reply.text == "Bonjour\nSam" && reply.cost == 0.003)
            } catch { #expect(expected != .succeeded) }
            #expect(TransformFixture.requests == 1)
            #expect(events.count == 2 && events[0].id == events[1].id)
            #expect(events.last?.operation == .reClean && events.last?.writingAction == "translation")
            #expect(events.last?.charge == 0.003 && events.last?.outcome == expected)
        }
    }
}
