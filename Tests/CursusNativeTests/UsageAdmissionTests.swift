import Foundation
import Testing
import CursusCore
@testable import CursusVox

private final class AdmissionTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requests: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 500,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func refusedUsageAdmissionNeverStartsAnyProviderTransport() async {
    AdmissionTransport.reset()
    let cloud = CloudSpeech(protocolClasses: [AdmissionTransport.self])
    cloud.usageAdmission = { _ in false }
    do { _ = try await cloud.transcribe(wav: Data([0]), key: "synthetic-fixture-key"); Issue.record("admission must refuse") }
    catch { #expect(error as? CloudFailure == .accountingUnavailable) }
    let scribe = ScribeSpeech(protocolClasses: [AdmissionTransport.self])
    scribe.usageAdmission = { _ in false }
    do { _ = try await scribe.transcribe(wav: Data([0]), key: "synthetic-fixture-key"); Issue.record("admission must refuse") }
    catch { #expect(error as? CloudFailure == .accountingUnavailable) }
    let cleaner = AICleanup(protocolClasses: [AdmissionTransport.self])
    cleaner.usageAdmission = { _ in false }
    let result = await cleaner.clean("hello world", rules: "Hello world.", context: CleanupContext(),
        vocabulary: Vocabulary(terms: []), key: "synthetic-fixture-key", budget: 1)
    #expect(result.text == "Hello world.")
    #expect(result.note?.contains("usage could not be saved") == true)
    #expect(AdmissionTransport.requests == 0)
    cloud.usageAdmission = { _ in true }
    do { _ = try await cloud.transcribe(wav: Data([0]), key: "synthetic-fixture-key") }
    catch { #expect(error as? CloudFailure == .status(500)) }
    // An admitted 5xx moves on to the two backup models, each admitted separately.
    #expect(AdmissionTransport.requests == 3)
}
