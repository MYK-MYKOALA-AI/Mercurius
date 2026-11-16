import Foundation

// Metadata endpoints share a receiving limit, not just a JSON parsing limit.
enum MetadataResponse {
    enum Failure: Error { case tooLarge }

    @concurrent nonisolated static func data(for request: URLRequest, session: URLSession,
                                             limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoCredentialRedirects())
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= limit else { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw Failure.tooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
