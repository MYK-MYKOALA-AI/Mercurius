import Foundation

// A YouTube clip gets the video's captions as a "Transcript" section. Only youtube.com / youtu.be
// video pages, only YouTube's own hosts are contacted, with an ephemeral session (no cookies, no
// account). The web page's caption links now need an anti-bot token, so the captions list comes from
// the same player API the iOS app uses. If YouTube refuses, the note says so and the clip still saves.
enum YouTubeTranscript {
    struct Line: Equatable, Sendable { let seconds: Int; let text: String }

    // The video's name from a browser window title: "(3) Some video - YouTube - Audio playing - Comet"
    // → "Some video" (the leading count is YouTube's unread notifications).
    static func title(fromWindow title: String) -> String {
        var name = title
        // The site's own suffix: " - YouTube" at the end or before another " - " segment (tab state, browser).
        var search = name.endIndex
        while let range = name.range(of: " - YouTube", options: .backwards, range: name.startIndex..<search) {
            let rest = name[range.upperBound...]
            if rest.isEmpty || rest.hasPrefix(" - ") { name = String(name[..<range.lowerBound]); break }
            search = range.lowerBound
        }
        if let count = name.range(of: #"^\(\d{1,4}\+?\) "#, options: .regularExpression) { name.removeSubrange(count) }
        return name.trimmingCharacters(in: .whitespaces)
    }
    static func videoID(_ address: String) -> String? {
        guard let url = URL(string: address), let host = url.host?.lowercased() else { return nil }
        let id: String?
        if host == "youtu.be" {
            id = url.pathComponents.dropFirst().first
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            if url.path == "/watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if url.pathComponents.count >= 3, ["shorts", "live", "embed"].contains(url.pathComponents[1]) {
                id = url.pathComponents[2]
            } else { id = nil }
        } else { id = nil }
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    static func render(_ lines: [Line]) -> String {
        lines.map { line in
            let stamp = line.seconds >= 3600
                ? String(format: "%d:%02d:%02d", line.seconds / 3600, line.seconds / 60 % 60, line.seconds % 60)
                : String(format: "%d:%02d", line.seconds / 60, line.seconds % 60)
            return "[\(stamp)] \(line.text)"
        }.joined(separator: "\n")
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()
    private static let agent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3 like Mac OS X;)"
    static let byteLimit = 4 * 1024 * 1024

    // Never follows a redirect: every request stays on the host it was checked against.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
    // Reads at most byteLimit bytes, stopping the download as soon as it would exceed it.
    private static func capped(_ request: URLRequest) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(for: request, delegate: NoRedirects()),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit { bytes.task.cancel(); return nil }
            }
        } catch { return nil }
        return data
    }

    static func fetch(id: String) async -> [Line]? {
        var player = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        player.httpMethod = "POST"
        player.setValue("application/json", forHTTPHeaderField: "Content-Type")
        player.setValue(agent, forHTTPHeaderField: "User-Agent")
        let context: [String: Any] = ["context": ["client": ["clientName": "IOS", "clientVersion": "20.10.4",
                                                              "deviceModel": "iPhone16,2", "hl": "en"]], "videoId": id]
        player.httpBody = try? JSONSerialization.data(withJSONObject: context)
        guard let data = await capped(player),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let track = chooseTrack(root),
              var parts = URLComponents(string: track), parts.scheme == "https", parts.host == "www.youtube.com"
        else { return nil }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "fmt" } + [URLQueryItem(name: "fmt", value: "json3")]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let body = await capped(request) else { return nil }
        return parse(json3: body)
    }

    // English captions written by a person, then English auto-captions, then whatever comes first.
    static func chooseTrack(_ root: [String: Any]) -> String? {
        let tracks = ((root["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any])?["captionTracks"]
            as? [[String: Any]] ?? []
        func english(_ track: [String: Any]) -> Bool { (track["languageCode"] as? String)?.hasPrefix("en") == true }
        let pick = tracks.first { english($0) && $0["kind"] as? String != "asr" }
            ?? tracks.first { english($0) } ?? tracks.first
        return pick?["baseUrl"] as? String
    }

    static func parse(json3 data: Data) -> [Line]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return nil }
        return events.compactMap { event -> Line? in
            let text = ((event["segs"] as? [[String: Any]]) ?? []).compactMap { $0["utf8"] as? String }.joined()
                .replacingOccurrences(of: "\n", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { return nil }
            return Line(seconds: ((event["tStartMs"] as? Int) ?? 0) / 1000, text: text)
        }
    }
}
