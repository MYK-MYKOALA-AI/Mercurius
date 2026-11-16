import Foundation

// A folder held open by its descriptor. Everything done in it (making a file, replacing,
// renaming or removing one, reading one, listing, opening a folder inside it) happens relative
// to that descriptor, never by path, and never through a link: a folder swapped for a link, or a link
// planted where a file should be, after the folder was opened can't send anything elsewhere.
// The Clips vault (ClipsVault) and the Clipboard's own files (ClipboardDisk) both use this, so
// there is one implementation to get right. The descriptor closes with the object.
final class SafeFolder: @unchecked Sendable {   // the descriptor is fixed for the object's life
    enum Problem: Error, Equatable {
        case link               // a link where a folder (or the file) should be
        case notAFolder(String) // a file where a folder should be
        case exists             // `create`: the name is taken
        case notVerified        // what was written didn't read back the same
        case rejected           // the caller refused where the file turned out to be
        case system(Int32)      // anything else, as errno
    }
    enum Kind: Sendable { case file, folder, link, other }
    struct Entry: Equatable, Sendable { let name: String; let kind: Kind; let modified: Date; let size: Int }

    let fd: Int32
    private init(_ fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    private static let folderFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC

    // Opens the folder at `url`. With `followLink` the folder itself may be a link (a vault you
    // keep elsewhere); otherwise a link there is refused. The folders above it are the user's own.
    // A missing folder is made when `create` (its parents too). With `mode`, the folder's
    // permissions are set back to it; `requireMode` makes failing to do so an error.
    static func open(_ url: URL, followLink: Bool, create: Bool, mode: mode_t? = nil, requireMode: Bool = true) throws -> SafeFolder {
        let flags = folderFlags | (followLink ? 0 : O_NOFOLLOW)
        var fd = Darwin.open(url.path, flags)
        if fd < 0, errno == ENOENT, create {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(url.path, mode ?? 0o700) != 0, errno != EEXIST { throw Problem.system(errno) }
            fd = Darwin.open(url.path, flags)
        }
        guard fd >= 0 else { throw failure(errno, in: AT_FDCWD, url.path, name: url.lastPathComponent) }
        let folder = SafeFolder(fd)
        if let mode, fchmod(fd, mode) != 0, requireMode { throw Problem.system(errno) }
        return folder
    }

    // Set the same binary-plist metadata as Foundation, on this open folder rather than a mutable path.
    func excludeFromBackup() throws {
        let name = "com.apple.metadata:com_apple_backup_excludeItem"
        let data = try PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0)
        let result = data.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
        guard result == 0 else { throw Problem.system(errno) }
        var check = Data(count: data.count)
        let count = check.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
        guard count == data.count, check == data else { throw Problem.notVerified }
    }

    // A folder inside this one, never reached through a link. Made (0700) when missing and `create`.
    func folder(_ name: String, create: Bool) throws -> SafeFolder {
        guard Self.plain(name) else { throw Problem.system(EINVAL) }
        let flags = Self.folderFlags | O_NOFOLLOW
        var next = openat(fd, name, flags)
        if next < 0, errno == ENOENT, create {
            if mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw Problem.system(errno) }
            next = openat(fd, name, flags)
        }
        guard next >= 0 else { throw Self.failure(errno, in: fd, name, name: name) }
        return SafeFolder(next)
    }
    // The folder `parts` leads to, one part at a time from this one.
    func folder(_ parts: [String], create: Bool) throws -> SafeFolder {
        var current = self
        for part in parts { current = try current.folder(part, create: create) }
        return current
    }

    // Makes `name` as a new file (never replacing anything there, a link included), writes
    // `data`, flushes it and reads it back from the same descriptor. `accept` is shown the path
    // the file really has now (F_GETPATH on its descriptor) before it is kept. A file that can't
    // be written whole, doesn't read back the same, or isn't accepted is removed again. Returns
    // that path, so the caller only ever reports the file that was written.
    func create(_ name: String, data: Data, mode: mode_t = 0o600, accept: (URL) -> Bool = { _ in true }) throws -> URL {
        guard Self.plain(name) else { throw Problem.system(EINVAL) }
        let file = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else {
            let code = errno
            throw code == EEXIST ? Problem.exists : Problem.system(code)
        }
        var kept = false
        defer {
            if !kept { removeIfSame(name, as: file) }
            close(file)
        }
        if let code = Self.writeAll(file, data) { throw Problem.system(code) }
        if fsync(file) != 0 { throw Problem.system(errno) }
        guard Self.read(file, from: 0, limit: data.count) == data, let path = Self.path(of: file) else { throw Problem.notVerified }
        guard accept(path) else { throw Problem.rejected }
        kept = true
        return path
    }

    // Writes `data` to a new temporary file here, then renames it over `name` in one step, inside
    // this folder: a reader sees the old file or the new one, never part of either. A link at
    // `name` is replaced, never followed.
    func replace(_ name: String, data: Data, mode: mode_t = 0o600) throws {
        guard Self.plain(name) else { throw Problem.system(EINVAL) }
        let temp = ".\(UUID().uuidString).tmp"
        let file = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else { throw Problem.system(errno) }
        var failure = Self.writeAll(file, data)
        if failure == nil, fsync(file) != 0 { failure = errno }
        close(file)
        if failure == nil, renameat(fd, temp, fd, name) != 0 { failure = errno }
        if let failure { unlinkat(fd, temp, 0); throw Problem.system(failure) }
    }

    // Renames `name` to `to` inside this folder, only if nothing is at `to` already.
    @discardableResult func rename(_ name: String, to: String) -> Bool {
        Self.plain(name) && Self.plain(to) && renameatx_np(fd, name, fd, to, UInt32(RENAME_EXCL)) == 0
    }
    // Removes the file (or a link itself; never what it points at, and never a folder).
    @discardableResult func remove(_ name: String) -> Bool {
        Self.plain(name) && unlinkat(fd, name, 0) == 0
    }
    // Removes `name` only while it is still the file open as `file`.
    @discardableResult private func removeIfSame(_ name: String, as file: Int32) -> Bool {
        var open = stat(), here = stat()
        guard fstat(file, &open) == 0, fstatat(fd, name, &here, AT_SYMLINK_NOFOLLOW) == 0,
              open.st_dev == here.st_dev, open.st_ino == here.st_ino else { return false }
        return unlinkat(fd, name, 0) == 0
    }
    // Moves `name` to the Trash only if it is the file open as `file`, with no gap for another file
    // to take the name between the check and the move: whatever is at `name` first moves (atomically)
    // to a random hidden name only this call knows, is checked there, and goes to the Trash only if it
    // is that file; anything else is moved back. Nothing is deleted outright, so a file taken by
    // mistake is still in the Trash. Returns nil when it went to the Trash, else the name the file is
    // under now (back at `name`, or the hidden name when putting it back failed).
    static let trash: @Sendable (URL) -> Bool = { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil }
    private func trashIfStillSame(_ name: String, as file: Int32, trash: (URL) -> Bool) -> String? {
        let hidden = ".cursusvox-taking-" + UUID().uuidString
        guard renameatx_np(fd, name, fd, hidden, UInt32(RENAME_EXCL)) == 0 else { return name }
        var open = stat(), moved = stat()
        if fstat(file, &open) == 0, fstatat(fd, hidden, &moved, AT_SYMLINK_NOFOLLOW) == 0,
           open.st_dev == moved.st_dev, open.st_ino == moved.st_ino,
           let folder = path, trash(folder.appendingPathComponent(hidden)) {
            return nil
        }
        // Not ours, or the Trash refused it: back under its own name if that is still free.
        return renameatx_np(fd, hidden, fd, name, UInt32(RENAME_EXCL)) == 0 ? name : hidden
    }

    // Taking a file that someone else (a browser) is putting here: opened once, judged by `owns`
    // on that open file, read from it, then moved to the Trash only if the name still holds that same
    // file (trashIfStillSame). A swap before the open is judged as what it is; a swap after it is never moved.
    // `left`: nil once the file is in the Trash; otherwise the name it is still under here.
    enum Taken: Equatable { case notYet, refused, taken(Data, left: String?) }
    // `owns`: nil = can't tell yet (look again later), false = not ours, true = ours.
    func take(_ name: String, limit: Int, trash: (URL) -> Bool = SafeFolder.trash, owns: (Int32) -> Bool?) -> Taken {
        guard Self.plain(name) else { return .refused }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return errno == ENOENT ? .notYet : .refused }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { return .refused }
        guard info.st_size > 0 else { return .notYet }
        switch owns(file) {
        case nil: return .notYet
        case false?: return .refused
        case true?: break
        }
        guard let data = Self.read(file, from: 0, limit: limit) else { return .refused }
        return .taken(data, left: trashIfStillSame(name, as: file, trash: trash))
    }
    // Just the names in the folder (no "." or ".."), at most `limit`: no per-entry stat, for
    // folders like Downloads that are looked at often.
    func names(limit: Int = 20_000) -> Set<String> {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        lseek(copy, 0, SEEK_SET)
        guard let dir = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(dir) }
        rewinddir(dir)
        var found = Set<String>()
        while found.count < limit, let item = readdir(dir) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != ".", name != ".." { found.insert(name) }
        }
        return found
    }

    // A plain file's bytes, at most `limit`: a link, folder, FIFO, socket or device in its place
    // is refused before a byte is read (O_NONBLOCK keeps the open from waiting on a FIFO), and a
    // file bigger than the limit, or one that grows past it while read, is refused too.
    func read(_ name: String, limit: Int) -> Data? {
        guard Self.plain(name) else { return nil }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { return nil }
        return Self.read(file, from: 0, limit: limit)
    }

    // What is at `name`, without following a link; nil when nothing is (`missing` says why not).
    func entry(_ name: String) -> Entry? {
        guard Self.plain(name) else { return nil }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Self.entry(name, info)
    }
    // Nothing at all is at `name` (not even a link).
    func missing(_ name: String) -> Bool {
        var info = stat()
        return Self.plain(name) && fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }
    // The folder's entries (not "." or ".."), each as it is, never through a link; at most `limit`.
    func entries(limit: Int = 20_000) -> [Entry] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        lseek(copy, 0, SEEK_SET)
        guard let dir = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(dir) }
        rewinddir(dir)
        var found: [Entry] = []
        while found.count < limit, let item = readdir(dir) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != "..", let entry = entry(name) else { continue }
            found.append(entry)
        }
        return found
    }
    // The folder's real path now, as the system knows it.
    var path: URL? { Self.path(of: fd) }
    // Which folder this is (its device and inode): another folder put at the same path differs.
    struct Identity: Equatable, Sendable { let device: dev_t; let inode: ino_t }
    var identity: Identity? {
        var info = stat()
        return fstat(fd, &info) == 0 ? Identity(device: info.st_dev, inode: info.st_ino) : nil
    }

    // MARK: helpers

    // One name inside a folder: never empty, ".", ".." or holding a slash.
    static func plain(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") }
    static func path(of fd: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }
    // The real path of an existing file or folder, links and all resolved (nil when there is none).
    static func realPath(_ url: URL) -> String? {
        guard let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
    // Up to `limit` bytes from an open plain file, from `offset`; nil on an error or if there are more.
    static func read(_ fd: Int32, from offset: off_t, limit: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var at = offset
        while true {
            let got = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, at) }
            if got < 0 { if errno == EINTR { continue }; return nil }
            if got == 0 { return data }
            data.append(contentsOf: chunk[..<got]); at += off_t(got)
            if data.count > limit { return nil }
        }
    }
    // Writes all of `data`; the errno when that failed.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Int32? {
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let wrote = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if wrote < 0 { if errno == EINTR { continue }; failure = errno; return }
                offset += wrote
            }
        }
        return failure
    }
    private static func entry(_ name: String, _ info: stat) -> Entry {
        let kind: Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .folder
        case S_IFLNK: .link
        default: .other
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return Entry(name: name, kind: kind, modified: modified, size: Int(info.st_size))
    }
    // Why opening `path` (in `dir`) failed: a link or a file in a folder's place says so.
    private static func failure(_ code: Int32, in dir: Int32, _ path: String, name: String) -> Problem {
        var info = stat()
        if fstatat(dir, path, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK { return .link }
            if (info.st_mode & S_IFMT) != S_IFDIR && code != EEXIST { return .notAFolder(name) }
        }
        return code == ELOOP ? .link : .system(code)
    }
}
