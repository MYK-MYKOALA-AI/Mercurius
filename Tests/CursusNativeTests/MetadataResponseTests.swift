import Foundation
import Synchronization
import Testing
@testable import CursusVox

private final class MetadataFixture: URLProtocol, @unchecked Sendable {
    static let reply = Mutex<(Data, [String: String])>((Data(), [:]))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, headers) = Self.reply.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct MetadataResponseTests {
    @Test func acceptsExactLimitAndEmptyReplies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for payload in [Data(), Data([1, 2, 3, 4])] {
            MetadataFixture.reply.withLock { $0 = (payload, [:]) }
            let (data, _) = try await MetadataResponse.data(for: URLRequest(url: URL(string: "https://metadata.example.test/")!), session: session, limit: 4)
            #expect(data == payload)
        }
    }

    @Test func rejectsOversizedDeclaredAndUnknownLengthReplies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for headers in [["Content-Length": "5"], [:]] {
            MetadataFixture.reply.withLock { $0 = (Data([1, 2, 3, 4, 5]), headers) }
            await #expect(throws: MetadataResponse.Failure.self) {
                _ = try await MetadataResponse.data(for: URLRequest(url: URL(string: "https://metadata.example.test/")!), session: session, limit: 4)
            }
        }
        MetadataFixture.reply.withLock { $0 = (Data([1]), [:]) }
        let (data, _) = try await MetadataResponse.data(for: URLRequest(url: URL(string: "https://metadata.example.test/")!), session: session, limit: 4)
        #expect(data == Data([1]))
    }
}
