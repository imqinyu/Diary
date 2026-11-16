import Darwin
import Foundation

struct SyncLocalSnapshot {
    let data: [String: Data]
    var hashes: [String: String] { data.mapValues(SyncHash.blob) }
}

struct SyncFileStore {
    let directory: URL
    private let fm = FileManager.default
    static let maximumFileSize = 90 * 1024 * 1024

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Diary/GitHubSync", isDirectory: true)
    }

    func namespace(repository: GitHubRepository, root: URL) -> SyncFileStore {
        let key = SyncHash.key("\(repository.id):\(repository.default_branch):\(root.resolvingSymlinksInPath().path)")
        return SyncFileStore(directory: directory.appendingPathComponent(key, isDirectory: true))
    }

    func loadState() throws -> SyncState {
        let url = directory.appendingPathComponent("state.json")
        guard fm.fileExists(atPath: url.path) else { return SyncState() }
        guard let state = try? JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url)), state.schema == 1,
              state.files.allSatisfy({ SyncPath.isAllowed($0.key) && isSHA($0.value) }),
              Set(state.conflicts.map(\.path)).count == state.conflicts.count,
              state.conflicts.allSatisfy({ SyncPath.isAllowed($0.path) && isSHA($0.id, length: 64)
                  && ($0.localSHA.map { isSHA($0) } ?? true) && ($0.remoteSHA.map { isSHA($0) } ?? true) }),
              state.resolutions.allSatisfy({ SyncPath.isAllowed($0.key)
                  && ($0.value.localSHA.map { isSHA($0) } ?? true) && ($0.value.remoteSHA.map { isSHA($0) } ?? true) }) else {
            throw DiarySyncError.invalidState
        }
        return state
    }

    func saveState(_ state: SyncState) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    func readBlob(_ sha: String) -> Data? {
        guard isSHA(sha), let data = try? Data(contentsOf: directory.appendingPathComponent("objects/" + sha)),
              SyncHash.blob(data) == sha else { return nil }
        return data
    }

    func saveBlob(_ data: Data, sha: String) throws {
        guard isSHA(sha), SyncHash.blob(data) == sha else { throw GitHubError.invalidData }
        let objects = directory.appendingPathComponent("objects", isDirectory: true)
        try fm.createDirectory(at: objects, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: objects.appendingPathComponent(sha), options: .atomic)
    }

    func saveConflict(path: String, local: Data?, remote: Data?) throws -> SyncConflict {
        let localSHA = local.map(SyncHash.blob), remoteSHA = remote.map(SyncHash.blob)
        let id = SyncHash.key("\(path):\(localSHA ?? "deleted"):\(remoteSHA ?? "deleted")")
        let folder = directory.appendingPathComponent("conflicts/" + id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let local { try local.write(to: folder.appendingPathComponent("local"), options: .atomic) }
        if let remote { try remote.write(to: folder.appendingPathComponent("remote"), options: .atomic) }
        let conflict = SyncConflict(id: id, path: path, localSHA: localSHA, remoteSHA: remoteSHA)
        try JSONEncoder().encode(conflict).write(to: folder.appendingPathComponent("info.json"), options: .atomic)
        return conflict
    }

    func conflictData(_ conflict: SyncConflict, choice: SyncChoice) -> Data? {
        guard isSHA(conflict.id, length: 64) else { return nil }
        let sha = choice == .local ? conflict.localSHA : conflict.remoteSHA
        guard let sha, let data = try? Data(contentsOf: directory.appendingPathComponent("conflicts/\(conflict.id)/\(choice.rawValue)")),
              SyncHash.blob(data) == sha else { return nil }
        return data
    }

    func conflictDirectory(_ conflict: SyncConflict) -> URL {
        directory.appendingPathComponent("conflicts/" + conflict.id, isDirectory: true)
    }

    func scan(root: URL) throws -> SyncLocalSnapshot {
        let entries = root.appendingPathComponent("entries", isDirectory: true)
        return try scanEntries(entries)
    }

    private func scanEntries(_ entries: URL) throws -> SyncLocalSnapshot {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let entryValues = try entries.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard entryValues.isSymbolicLink != true else { throw DiarySyncError.unsafePath("entries") }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: entries, includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw DiarySyncError.invalidState
        }
        let rootParts = entries.resolvingSymlinksInPath().pathComponents
        var data: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            guard values.isSymbolicLink != true else { throw DiarySyncError.unsafePath(url.lastPathComponent) }
            guard values.isRegularFile == true else { continue }
            let parts = url.resolvingSymlinksInPath().pathComponents
            guard Array(parts.prefix(rootParts.count)) == rootParts else { throw DiarySyncError.unsafePath(url.path) }
            let path = "entries/" + parts.dropFirst(rootParts.count).joined(separator: "/")
            guard SyncPath.isAllowed(path) else { throw DiarySyncError.unsafePath(path) }
            guard (values.fileSize ?? 0) <= Self.maximumFileSize else { throw DiarySyncError.oversizedFile(path) }
            let contents = try Data(contentsOf: url)
            guard contents.count <= Self.maximumFileSize else { throw DiarySyncError.oversizedFile(path) }
            data[path] = contents
        }
        if let enumerationError { throw enumerationError }
        return SyncLocalSnapshot(data: data)
    }

    func validate(_ files: [String: Data]) throws {
        var ids = Set<String>()
        for (path, data) in files {
            guard SyncPath.isAllowed(path) else { throw DiarySyncError.unsafePath(path) }
            guard data.count <= Self.maximumFileSize else { throw DiarySyncError.oversizedFile(path) }
            guard path.hasSuffix(".md"), !path.split(separator: "/").contains(where: { $0 == "assets" || $0.hasSuffix(".assets") }) else { continue }
            guard let text = String(data: data, encoding: .utf8) else { throw DiarySyncError.invalidEntry(path) }
            let doc = EntryDocument.decode(text)
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            guard let day = doc.frontMatter.string("date") ?? EntryFileName.parse(stem)?.dayKey,
                  let date = DayKey.date(from: day), DayKey.string(from: date) == day else { throw DiarySyncError.invalidEntry(path) }
            let id = doc.frontMatter.string("id") ?? stem
            guard ids.insert(id).inserted else { throw DiarySyncError.duplicateEntry(id) }
        }
    }

    /// 先在同一磁盘准备完整目录，最后原子交换，任何失败都保留原 entries。
    func apply(files: [String: Data], expected: [String: String], root: URL) throws -> Bool {
        if files.mapValues(SyncHash.blob) == expected { return false }
        try validate(files)
        let entries = root.appendingPathComponent("entries", isDirectory: true)
        let staging = root.appendingPathComponent(".diary-sync-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: entries, to: staging)
        defer { try? fm.removeItem(at: staging) }
        guard try scanEntries(staging).hashes == expected else { throw DiarySyncError.localChanged }
        for old in expected.keys where files[old] == nil {
            try fm.removeItem(at: staging.appendingPathComponent(String(old.dropFirst("entries/".count))))
        }
        for (path, data) in files where expected[path] != SyncHash.blob(data) {
            let target = staging.appendingPathComponent(String(path.dropFirst("entries/".count)))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        // 大小写不敏感磁盘上的路径冲突也必须在交换之前发现。
        guard try scanEntries(staging).hashes == files.mapValues(SyncHash.blob) else { throw DiarySyncError.invalidState }
        // 重新核对原目录，包含删除和新增，不覆盖准备期间出现的磁盘修改。
        guard try scan(root: root).hashes == expected else { throw DiarySyncError.localChanged }
        let status = staging.withUnsafeFileSystemRepresentation { stagedPath in
            entries.withUnsafeFileSystemRepresentation { entryPath in
                renamex_np(stagedPath!, entryPath!, UInt32(RENAME_SWAP))
            }
        }
        guard status == 0 else { throw DiarySyncError.diskSwap(errno) }
        return true
    }

    private func isSHA(_ string: String, length: Int = 40) -> Bool {
        string.count == length && string.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
