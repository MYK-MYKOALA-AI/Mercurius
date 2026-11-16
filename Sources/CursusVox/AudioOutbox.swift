import Foundation
import CursusCore

// A recording whose transcription failed is kept so it can be retried instead
// of spoken again (Sol, Grok and Muse, 2026-10-13). Files live in a private
// cache folder (0700, files 0600), at most three, and are deleted after a
// successful retry or ten minutes. They are never logged or synced.
final class AudioOutbox: @unchecked Sendable {
    struct Item: Codable, Equatable { let id: UUID; let at: Date; let seconds: Double; var configuration: RecoveryConfiguration? = nil }
    static let lifetime: TimeInterval = 600
    static let keep = 3
    static let shared = AudioOutbox(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("au.com.mykoala.mercurius/outbox", isDirectory: true))
    let directory: URL
    private let lock = NSLock()
    private var items: [Item] = []
    private var lastProblem: String?
    var problem: String? { lock.withLock { lastProblem } }
    private func folder(create: Bool = false) -> SafeFolder? {
        do {
            let folder = try SafeFolder.open(directory, followLink: false, create: create, mode: 0o700)
            try folder.excludeFromBackup()
            return folder
        } catch SafeFolder.Problem.system(let code) where code == ENOENT && !create {
            return nil
        } catch {
            lastProblem = "Recording recovery storage is unavailable. Check free space and folder access."
            return nil
        }
    }

    private struct Manifest: Codable { var version = 1; var items: [Item] }
    init(directory: URL, now: Date = Date()) {
        self.directory = directory
        if let storage = folder(), storage.entry("index.json")?.kind == .file {
            if let data = storage.read("index.json", limit: 128 * 1024),
               let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1 {
                items = Array(manifest.items.filter { now.timeIntervalSince($0.at) >= 0 && now.timeIntervalSince($0.at) < Self.lifetime &&
                    storage.entry($0.id.uuidString + ".wav")?.kind == .file }.suffix(Self.keep))
            } else {
                // The index is unreadable. Recover the recordings from the files themselves: each is
                // named after its identity and its age is its own modification date, so it can still be
                // offered for retry. Files past the retention window are not recovered and the purge
                // below removes them, so a broken index can neither lose a recording nor strand one
                // past the ten-minute limit. The repaired index is persisted by that same purge.
                lastProblem = "A saved recording index could not be read; recordings were recovered from the files."
                items = Array(storage.entries().compactMap { entry -> Item? in
                    guard entry.kind == .file, entry.name.hasSuffix(".wav"), entry.size >= 44,
                          let id = UUID(uuidString: String(entry.name.dropLast(4))),
                          now.timeIntervalSince(entry.modified) >= 0,
                          now.timeIntervalSince(entry.modified) < Self.lifetime else { return nil }
                    return Item(id: id, at: entry.modified, seconds: Double(entry.size - 44) / 32_000, configuration: nil)
                }.suffix(Self.keep))
            }
        }
        purge(now: now)
    }
    private func persist() -> Bool {
        do {
            guard let storage = folder(create: true) else { return false }
            try storage.replace("index.json", data: JSONEncoder().encode(Manifest(items: items)))
            return true
        } catch { lastProblem = "Recording recovery index could not be saved. Check free space and folder access."; return false }
    }

    func save(_ wav: Data, now: Date = Date(), configuration: RecoveryConfiguration? = nil) -> Item? {
        lock.withLock {
            guard wav.count <= Policy.audioLimit, wav.count >= 44 else { return nil }
            lastProblem = nil
            guard let storage = folder(create: true) else { return nil }
            let item = Item(id: UUID(), at: now, seconds: Double(max(0, wav.count - 44)) / 32_000, configuration: configuration)
            do { _ = try storage.create(file(item.id).lastPathComponent, data: wav) }
            catch { lastProblem = "Recording could not be retained for retry. Check free space and folder access."; return nil }
            items.append(item)
            while items.count > Self.keep { remove(items.removeFirst().id) }
            guard persist() else { items.removeAll { $0.id == item.id }; remove(item.id); return nil }
            return item
        }
    }
    func list(now: Date = Date()) -> [Item] { lock.withLock { purgeLocked(now); return items } }
    func data(_ item: Item, now: Date = Date()) -> Data? { lock.withLock {
        guard let saved = items.first(where: { $0.id == item.id }), now.timeIntervalSince(saved.at) >= 0, now.timeIntervalSince(saved.at) < Self.lifetime,
              let data = folder()?.read(file(item.id).lastPathComponent, limit: Policy.audioLimit) else { return nil }; return data
    } }
    func url(for item: Item) -> URL? { lock.withLock {
        guard let saved = items.first(where: { $0.id == item.id }), Date().timeIntervalSince(saved.at) >= 0, Date().timeIntervalSince(saved.at) < Self.lifetime else { return nil }; return file(item.id)
    } }
    func discard(_ item: Item) { lock.withLock { items.removeAll { $0.id == item.id }; remove(item.id); _ = persist() } }
    // Also clears files left by an earlier run (crash or quit), which the list doesn't know about.
    func purge(now: Date = Date(), all: Bool = false) {
        lock.withLock {
            if all { items.removeAll() }
            purgeLocked(now)
            let known = Set(items.map { file($0.id).lastPathComponent })
            if let storage = folder() {
                for entry in storage.entries() where !known.contains(entry.name) && entry.name != "index.json" && entry.kind != .folder {
                    if !storage.remove(entry.name) { lastProblem = "Expired recording files could not be deleted. Check folder access." }
                }
                if all, !storage.missing("index.json"), !storage.remove("index.json") {
                    lastProblem = "Recording recovery index could not be deleted. Check folder access."
                }
            }
            if !all && !items.isEmpty { _ = persist() }
        }
    }
    private func purgeLocked(_ now: Date) {
        for item in items where now.timeIntervalSince(item.at) >= Self.lifetime { remove(item.id) }
        let previous = items.count
        items.removeAll { now.timeIntervalSince($0.at) >= Self.lifetime }
        if previous != items.count { _ = persist() }
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".wav") }
    private func remove(_ id: UUID) {
        guard let storage = folder() else { return }
        let name = file(id).lastPathComponent
        if !storage.missing(name), !storage.remove(name) { lastProblem = "Expired recording could not be deleted. Check folder access." }
    }
}
