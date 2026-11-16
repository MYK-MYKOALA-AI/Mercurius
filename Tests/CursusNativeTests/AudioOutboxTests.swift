import Foundation
import Testing
@testable import CursusVox

private func outbox() -> AudioOutbox {
    AudioOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("cv-outbox-\(UUID().uuidString)"))
}
private let wav = Data(repeating: 1, count: 44 + 32_000 * 3)

@Test func failedAudioIsKeptPrivatelyAndExpires() throws {
    let box = outbox(); defer { try? FileManager.default.removeItem(at: box.directory) }
    let start = Date(timeIntervalSince1970: 1_000)
    let item = try #require(box.save(wav, now: start))
    #expect(abs(item.seconds - 3) < 0.01)
    let file = box.directory.appendingPathComponent(item.id.uuidString + ".wav")
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: box.directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(box.data(item, now: start) == wav)
    #expect(box.list(now: start.addingTimeInterval(599)) == [item])
    #expect(box.list(now: start.addingTimeInterval(600)).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func outboxKeepsOnlyTheNewestThreeAndClearsLeftovers() throws {
    let box = outbox(); defer { try? FileManager.default.removeItem(at: box.directory) }
    let now = Date()
    let saved = (0..<5).compactMap { box.save(wav, now: now.addingTimeInterval(Double($0))) }
    #expect(box.list(now: now) == Array(saved.suffix(3)))
    // A file from an earlier run is removed; the known ones stay.
    let stray = box.directory.appendingPathComponent("old.wav")
    FileManager.default.createFile(atPath: stray.path, contents: wav)
    box.purge(now: now)
    #expect(!FileManager.default.fileExists(atPath: stray.path))
    #expect(box.list(now: now).count == 3)
    box.discard(saved[4])
    #expect(box.list(now: now).count == 2)
    box.purge(now: now, all: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: box.directory.path).isEmpty)
}

@Test func recoveryManifestSurvivesRestartAndKeepsOriginalSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 2000)
    let first = AudioOutbox(directory: directory, now: start)
    let item = try #require(first.save(wav,now: start, configuration: .init(engine: .local,speechModel: "apple-speech")))
    let restarted = AudioOutbox(directory: directory,now: start.addingTimeInterval(50))
    #expect(restarted.list(now: start.addingTimeInterval(50)) == [item])
    #expect(restarted.data(item,now: start.addingTimeInterval(50)) == wav)
    #expect(restarted.data(item,now: start.addingTimeInterval(600)) == nil)
    #expect(AudioOutbox(directory: directory,now: start.addingTimeInterval(600)).list().isEmpty)
}

@Test func outboxRefusesLinkedStorageAndMarksPrivateFolderExcludedFromBackup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
    let linked = AudioOutbox(directory: root)
    #expect(linked.save(wav) == nil); #expect(linked.problem != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    try FileManager.default.removeItem(at: root)
    let owned = AudioOutbox(directory: root)
    let saved = owned.save(wav)
    #expect(saved != nil)
    #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@Test func callerCannotRenewAnExpiredAudioItem() throws {
    let box = outbox(); defer { try? FileManager.default.removeItem(at: box.directory) }
    let at = Date().addingTimeInterval(-600)
    let saved = try #require(box.save(wav, now: at))
    let forged = AudioOutbox.Item(id: saved.id, at: Date(), seconds: saved.seconds)
    #expect(box.data(forged) == nil); #expect(box.url(for: forged) == nil)
}

// A truncated or corrupted index used to leave `items` empty, so purge treated every
// retained .wav as a stray and deleted the user's only copy, silently.
@Test func unreadableIndexRecoversRecordingsAndKeepsThemAcrossALaterSave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Real dates: recovery reads each recording's own file modification time.
    let start = Date()
    let item = try #require(AudioOutbox(directory: directory, now: start).save(wav, now: start))
    let file = directory.appendingPathComponent(item.id.uuidString + ".wav")
    try Data("not json".utf8).write(to: directory.appendingPathComponent("index.json"))
    let restarted = AudioOutbox(directory: directory, now: start.addingTimeInterval(5))
    #expect(restarted.problem != nil)
    #expect(restarted.list(now: start.addingTimeInterval(5)).map(\.id) == [item.id])
    // A later save must not orphan the recovered recording: the repaired index lists both.
    _ = restarted.save(wav, now: start.addingTimeInterval(6))
    let again = AudioOutbox(directory: directory, now: start.addingTimeInterval(7))
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(again.list(now: start.addingTimeInterval(7)).map(\.id).contains(item.id))
}

// Recovery must not defeat the ten-minute retention: an expired recording is still removed.
@Test func expiredRecordingWithAnUnreadableIndexIsStillRemoved() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stale = directory.appendingPathComponent(UUID().uuidString + ".wav")
    FileManager.default.createFile(atPath: stale.path, contents: wav)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: stale.path)
    try Data("not json".utf8).write(to: directory.appendingPathComponent("index.json"))
    _ = AudioOutbox(directory: directory, now: Date(timeIntervalSince1970: 1000 + AudioOutbox.lifetime + 1))
    #expect(!FileManager.default.fileExists(atPath: stale.path))
}
