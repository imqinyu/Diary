import Foundation
import Observation

enum BackupError: LocalizedError {
    case noFolder
    case folderNeedsAuthorization
    case archiveFailed(String)
    case unarchiveFailed(String)
    case invalidArchive
    case folderInsideDiary

    var errorDescription: String? {
        switch self {
        case .noFolder:
            return "还没有选择备份文件夹"
        case .folderNeedsAuthorization:
            return "请重新选择备份文件夹，以保存访问授权"
        case .archiveFailed(let message):
            return "打包失败：\(message)"
        case .unarchiveFailed(let message):
            return "解包失败：\(message)"
        case .invalidArchive:
            return "这个压缩包里没有找到 entries 目录，可能不是日记备份"
        case .folderInsideDiary:
            return "备份文件夹不能放在日记目录里面"
        }
    }
}

/// 定期把整个日记目录打成 zip 放到用户选的外部文件夹。
/// 用 /usr/bin/ditto 打包，恢复时也用它解包，格式就是普通 zip，任何平台都能打开。
@MainActor
@Observable
final class BackupManager {
    static let maxBackups = 5

    private(set) var folderPath: String?
    private(set) var lastBackupDate: Date?
    private(set) var isBusy = false

    var errorMessage: String?
    var infoMessage: String?

    var intervalDays: Int {
        didSet {
            let clamped = min(max(intervalDays, 1), 7)
            if clamped != intervalDays {
                intervalDays = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.interval)
        }
    }

    private let defaults: UserDefaults
    private var folderAccess: BackupFolderAccess?

    private enum Keys {
        static let folder = "BackupFolderPath"
        static let bookmark = "BackupFolderBookmark"
        static let interval = "BackupIntervalDays"
        static let lastDate = "BackupLastDate"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folderPath = defaults.string(forKey: Keys.folder)
        lastBackupDate = defaults.object(forKey: Keys.lastDate) as? Date
        intervalDays = (defaults.object(forKey: Keys.interval) as? Int) ?? 3
        if let bookmark = defaults.data(forKey: Keys.bookmark) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                let access = BackupFolderAccess(url: url)
                if stale {
                    let refreshed = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    defaults.set(refreshed, forKey: Keys.bookmark)
                }
                folderAccess = access
                folderPath = url.path
                defaults.set(url.path, forKey: Keys.folder)
            } catch {
                // 失效授权只在界面提示重新选择，不自动访问旧路径或弹系统授权框。
                folderAccess = nil
            }
        }
    }

    // MARK: - 状态

    var folderURL: URL? {
        folderAccess?.url ?? folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var isConfigured: Bool {
        folderPath != nil
    }

    var needsFolderAuthorization: Bool {
        isConfigured && folderAccess == nil
    }

    var needsBackup: Bool {
        guard folderAccess != nil else { return false }
        guard let lastBackupDate else { return true }
        let days = Calendar.current.dateComponents([.day], from: lastBackupDate, to: Date()).day ?? 0
        return days >= intervalDays
    }

    /// 下次自动备份的时间，界面上用来给用户一个预期。
    var nextBackupDate: Date? {
        guard let lastBackupDate else { return nil }
        return Calendar.current.date(byAdding: .day, value: intervalDays, to: lastBackupDate)
    }

    // MARK: - 设置

    func setFolder(_ url: URL, dataRoot: URL) throws {
        let access = BackupFolderAccess(url: url)
        let target = url.standardizedFileURL
        let resolvedTarget = target.resolvingSymlinksInPath()
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        if resolvedTarget.path == root.path || resolvedTarget.path.hasPrefix(root.path + "/") {
            throw BackupError.folderInsideDiary
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        folderAccess = access
        folderPath = target.path
        defaults.set(target.path, forKey: Keys.folder)
        defaults.set(bookmark, forKey: Keys.bookmark)
        errorMessage = nil
    }

    // MARK: - 备份

    @discardableResult
    func backupNow(store: DiaryStore) async -> URL? {
        guard let access = folderAccess else {
            errorMessage = (isConfigured ? BackupError.folderNeedsAuthorization : .noFolder).errorDescription
            return nil
        }
        guard !isBusy else { return nil }

        isBusy = true
        defer { isBusy = false }
        // 更改设置也不能在异步打包结束前释放这次操作的目录授权。
        defer { withExtendedLifetime(access) {} }
        let folderURL = access.url

        let source = store.dataRoot
        let destination = folderURL.appendingPathComponent("Diary-\(Self.stamp()).zip")

        do {
            try await makeArchive(from: source, to: destination)
            lastBackupDate = Date()
            defaults.set(lastBackupDate, forKey: Keys.lastDate)
            pruneOldBackups(in: folderURL)
            infoMessage = "已备份 \(destination.lastPathComponent)"
            errorMessage = nil
            return destination
        } catch {
            errorMessage = "备份失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 启动时调用：到点了就自动备份一次。
    func autoBackupIfNeeded(store: DiaryStore) async {
        guard needsBackup, !isBusy else { return }
        await backupNow(store: store)
    }

    /// 手动导出到用户指定位置。
    func export(to destination: URL, store: DiaryStore) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await makeArchive(from: store.dataRoot, to: destination)
            infoMessage = "已导出到 \(destination.lastPathComponent)"
            errorMessage = nil
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 恢复

    func backups() -> [URL] {
        guard let access = folderAccess else { return [] }
        let folderURL = access.url
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "zip" && $0.lastPathComponent.hasPrefix("Diary-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 用某个备份替换当前日记。替换前会先自动打一个保险备份。
    @discardableResult
    func restore(from archive: URL, store: DiaryStore) async -> Bool {
        guard !isBusy else { return false }
        guard let access = folderAccess else {
            errorMessage = (isConfigured ? BackupError.folderNeedsAuthorization : .noFolder).errorDescription
            return false
        }
        isBusy = true
        defer { isBusy = false }
        defer { withExtendedLifetime(access) {} }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("DiaryRestore-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) {
                try Self.runDitto(["-x", "-k", archive.path, workspace.path])
            }.value

            let importedEntries = try Self.locateEntries(in: workspace)

            // 先留一份现状，万一恢复的内容不对还能回去
            let folderURL = access.url
            let safety = folderURL.appendingPathComponent("Diary-替换前-\(Self.stamp()).zip")
            try await makeArchive(from: store.dataRoot, to: safety)
            lastBackupDate = Date()
            defaults.set(lastBackupDate, forKey: Keys.lastDate)
            pruneOldBackups(in: folderURL)

            let current = store.dataRoot.appendingPathComponent("entries", isDirectory: true)
            let old = workspace.appendingPathComponent("entries-old", isDirectory: true)
            if fileManager.fileExists(atPath: current.path) {
                try fileManager.moveItem(at: current, to: old)
            }
            do {
                try fileManager.moveItem(at: importedEntries, to: current)
            } catch {
                if fileManager.fileExists(atPath: old.path) {
                    try fileManager.moveItem(at: old, to: current)
                }
                throw error
            }
            store.reload()

            if store.entries.isEmpty && !Self.containsEntries(at: old) {
                // 备份里本来就是空的，没什么可回滚的
                infoMessage = "已恢复（备份里没有条目）"
            } else if store.entries.isEmpty {
                try? fileManager.removeItem(at: current)
                try? fileManager.moveItem(at: old, to: current)
                store.reload()
                throw BackupError.invalidArchive
            } else {
                infoMessage = "已恢复 \(store.entries.count) 条日记"
            }

            errorMessage = nil
            try? fileManager.removeItem(at: workspace)
            return true
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
            if fileManager.fileExists(atPath: workspace.appendingPathComponent("entries-old").path) {
                errorMessage = "恢复失败，原日记保留在 \(workspace.path)：\(error.localizedDescription)"
            } else {
                try? fileManager.removeItem(at: workspace)
            }
            return false
        }
    }

    // MARK: - 内部

    private func pruneOldBackups(in folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let backups = files
            .filter { $0.pathExtension.lowercased() == "zip" && $0.lastPathComponent.hasPrefix("Diary-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(Self.maxBackups) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private func makeArchive(from source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: destination)
            try Self.runDitto(["-c", "-k", "--sequesterRsrc", source.path, destination.path])
        }.value
    }

    private static func locateEntries(in workspace: URL) throws -> URL {
        let fileManager = FileManager.default
        let direct = workspace.appendingPathComponent("entries", isDirectory: true)
        if fileManager.fileExists(atPath: direct.path) { return direct }

        // 兼容有人用访达「压缩」出来的、外面多套一层的压缩包
        let children = (try? fileManager.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for child in children {
            let nested = child.appendingPathComponent("entries", isDirectory: true)
            if fileManager.fileExists(atPath: nested.path) { return nested }
        }
        throw BackupError.invalidArchive
    }

    private static func containsEntries(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "md" {
            return true
        }
        return false
    }

    nonisolated private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ditto 退出码 \(process.terminationStatus)"
            throw BackupError.archiveFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    static func stamp() -> String {
        stampFormatter.string(from: Date())
    }
}

/// 与授权 URL 一起持有访问权限；异步操作保留实例直到完成。
private final class BackupFolderAccess {
    let url: URL
    private let didStartAccess: Bool

    init(url: URL) {
        self.url = url
        didStartAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess { url.stopAccessingSecurityScopedResource() }
    }
}
