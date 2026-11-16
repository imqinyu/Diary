import AppKit
import Foundation

@main
struct StorageBackupChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("DiaryStorageChecks-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = workspace.appendingPathComponent("Diary")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(["DiaryDataRootPath": root.path], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let suite = "DiaryStorageChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyManager(defaults: defaults, auditLog: PrivacyAuditLog(fileURL: workspace.appendingPathComponent("audit.json")))
        precondition(privacy.setPassword("test-password"))
        let key = privacy.encryptionKey!
        let today = DayKey.today()
        let entriesRoot = root.appendingPathComponent("entries")
        let year = entriesRoot.appendingPathComponent(String(today.prefix(4)))
        func legacy(_ day: String, _ sequence: Int, encrypted: Bool = false, deleted: Bool = false) throws -> URL {
            let stem = EntryFileName.stem(dayKey: day, sequence: sequence)
            let file = entriesRoot.appendingPathComponent(String(day.prefix(4))).appendingPathComponent(stem + ".md")
            var frontMatter = FrontMatter()
            frontMatter.set("id", .scalar(stem))
            frontMatter.set("date", .scalar(day))
            frontMatter.set("updated", .scalar("2026-01-01T00:00:00Z"))
            frontMatter.set("custom_field", .scalar("preserved"))
            frontMatter.set("private", .scalar(encrypted ? "true" : "false"))
            frontMatter.set("encrypted", .scalar(encrypted ? "true" : "false"))
            frontMatter.set("deleted", .scalar(deleted ? "true" : "false"))
            let body = deleted ? "" : "Hello ![](\(stem).assets/same.png)"
            try EntryDocument(frontMatter: frontMatter, body: encrypted ? PrivacyCrypto.seal(body, key: key)! : body).write(to: file)
            let assets = file.deletingPathExtension().appendingPathExtension("assets")
            try fm.createDirectory(at: assets, withIntermediateDirectories: true)
            try Data([UInt8(sequence)]).write(to: assets.appendingPathComponent("same.png"))
            return file
        }
        let first = try legacy(today, 1)
        let second = try legacy(today, 2)
        let secret = try legacy(today, 3, encrypted: true)
        let past = try legacy("2020-01-02", 1)
        let tombstone = try legacy("2020-01-02", 2, deleted: true)
        var firstDocument = try EntryDocument.read(from: first)
        firstDocument.body += " ![](extra.png) ![](../../extra.png)"
        try firstDocument.write(to: first)
        try Data([99]).write(to: year.appendingPathComponent("extra.png"))
        try Data([88]).write(to: root.appendingPathComponent("extra.png"))
        let secretBefore = try Data(contentsOf: secret)
        privacy.lock()
        let store = DiaryStore(privacy: privacy)
        precondition(store.entries.count == 5 && store.errorMessage == nil)
        precondition(!fm.fileExists(atPath: first.path) && !fm.fileExists(atPath: second.path))
        precondition(!fm.fileExists(atPath: past.path) && !fm.fileExists(atPath: tombstone.path))
        let lockedSecret = try Data(contentsOf: secret)
        precondition(lockedSecret == secretBefore)
        let day = DiaryStore.dayDirectory(for: today, under: entriesRoot)!
        precondition(day.path.hasSuffix(today.replacingOccurrences(of: "-", with: "/")))
        precondition(DiaryStore.dayDirectory(for: "2026-02-31", under: entriesRoot) == nil)
        precondition(DiaryStore.dayDirectory(for: "../../bad", under: entriesRoot) == nil)
        let migrated = store.entry(with: first.deletingPathExtension().lastPathComponent)!
        precondition(migrated.fileURL.deletingLastPathComponent() == day)
        let migratedDoc = try EntryDocument.read(from: migrated.fileURL)
        precondition(migratedDoc.frontMatter.string("custom_field") == "preserved")
        precondition(migratedDoc.frontMatter.string("updated") == "2026-01-01T00:00:00Z")
        for photo in store.photos() { precondition(fm.fileExists(atPath: photo.url.path)) }
        let firstPhotos = try store.photos(in: [migrated]).map { try Data(contentsOf: $0.url) }
        precondition(firstPhotos == [Data([1]), Data([99]), Data([88])])
        let snapshot = try Data(contentsOf: migrated.fileURL)
        store.reload()
        precondition(store.errorMessage == nil)
        let reloadedBytes = try Data(contentsOf: migrated.fileURL)
        precondition(reloadedBytes == snapshot)
        let unlocked = await privacy.tryUnlock("test-password")
        precondition(unlocked)
        store.reload()
        precondition(!fm.fileExists(atPath: secret.path))
        let movedSecret = store.entry(with: secret.deletingPathExtension().lastPathComponent)!
        let secretDocument = try EntryDocument.read(from: movedSecret.fileURL)
        precondition(secretDocument.frontMatter.bool("encrypted") == true)
        precondition(!secretDocument.body.contains("Hello"))
        precondition(PrivacyCrypto.open(secretDocument.body, key: key) == movedSecret.bodyMarkdown)
        for photo in store.photos() { precondition(fm.fileExists(atPath: photo.url.path)) }
        // 同日多篇、相同图片文件名也独立保存；删除一篇不影响其它篇。
        let other = store.entry(with: second.deletingPathExtension().lastPathComponent)!
        let otherImage = other.assetsDirectory.appendingPathComponent("same.png")
        precondition(store.deleteEntry(entryID: migrated.id))
        precondition(fm.fileExists(atPath: otherImage.path))
        let created = store.createTodayEntry()!
        precondition(created.fileURL.deletingLastPathComponent().resolvingSymlinksInPath() == day.resolvingSymlinksInPath() && created.sequence == 4,
                     "Unexpected new entry: \(created.fileURL.path), sequence \(created.sequence), expected day \(day.path)")
        let path = store.importImage(from: year.appendingPathComponent("extra.png"), for: created.id)!
        precondition(path.hasPrefix("assets/\(created.stem)/"))
        store.saveBody(entryID: created.id, markdown: "new ![](\(path))")

        let inserted = store.insertEntry(on: DayKey.date(from: "2024-06-10")!)!
        precondition(inserted.isBackfilled && inserted.editableUntil != nil)
        let insertedDocument = try EntryDocument.read(from: inserted.fileURL)
        precondition(insertedDocument.frontMatter.bool("backfilled") == true)
        store.reload()
        precondition(store.entry(with: inserted.id)?.isBackfilled == true)
        precondition(!created.isBackfilled)
        let blank = store.createTodayEntry()!
        precondition(!blank.needsDeletionConfirmation())
        precondition(store.deleteEntry(entryID: blank.id))
        precondition(!fm.fileExists(atPath: blank.fileURL.path))

        // 没有 updated 字段的老文件，迁移后仍使用原修改日期判断。
        var plainLegacy = FrontMatter()
        plainLegacy.set("date", .scalar("2024-02-02"))
        let plainFile = entriesRoot.appendingPathComponent("2024/2024-02-02-1.md")
        try EntryDocument(frontMatter: plainLegacy, body: "当天写的旧日记").write(to: plainFile)
        let oldModified = DayKey.date(from: "2024-02-02")!
        try fm.setAttributes([.modificationDate: oldModified], ofItemAtPath: plainFile.path)
        store.reload()
        let movedPlain = store.entry(with: "2024-02-02-1")!
        precondition(!movedPlain.isBackfilled && movedPlain.updated == oldModified)
        store.reload()
        precondition(store.entry(with: movedPlain.id)?.isBackfilled == false)

        // 同名目标不能被覆盖；移除冲突后可重试。损坏密文保持原样。
        let conflict = try legacy("2021-02-03", 1)
        let conflictTarget = DiaryStore.dayDirectory(for: "2021-02-03", under: entriesRoot)!
            .appendingPathComponent(conflict.lastPathComponent)
        try fm.createDirectory(at: conflictTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("existing file must survive".utf8)
        try sentinel.write(to: conflictTarget)
        store.reload()
        precondition(store.errorMessage != nil && fm.fileExists(atPath: conflict.path))
        let preservedTarget = try Data(contentsOf: conflictTarget)
        precondition(preservedTarget == sentinel)
        try fm.removeItem(at: conflictTarget)
        store.errorMessage = nil
        store.reload()
        precondition(store.errorMessage == nil && !fm.fileExists(atPath: conflict.path))
        var broken = FrontMatter()
        broken.set("id", .scalar("2018-01-02-1"))
        broken.set("date", .scalar("2018-01-02"))
        broken.set("private", .scalar("true"))
        broken.set("encrypted", .scalar("true"))
        let brokenFile = entriesRoot.appendingPathComponent("2018/2018-01-02-1.md")
        try EntryDocument(frontMatter: broken, body: "invalid ciphertext").write(to: brokenFile)
        let brokenBytes = try Data(contentsOf: brokenFile)
        store.reload()
        let unchangedBroken = try Data(contentsOf: brokenFile)
        precondition(unchangedBroken == brokenBytes)

        // 旧配置和损坏书签不扫描路径、不触发自动备份，也不抹掉已保存的位置。
        let folder = workspace.appendingPathComponent("Backups")
        defaults.set(folder.path, forKey: "BackupFolderPath")
        let legacyBackup = BackupManager(defaults: defaults)
        precondition(legacyBackup.isConfigured && legacyBackup.needsFolderAuthorization)
        precondition(!legacyBackup.needsBackup && legacyBackup.backups().isEmpty)
        defaults.set(Data([0, 1, 2]), forKey: "BackupFolderBookmark")
        precondition(BackupManager(defaults: defaults).needsFolderAuthorization)
        let backup = BackupManager(defaults: defaults)
        try backup.setFolder(folder, dataRoot: root)
        precondition(defaults.data(forKey: "BackupFolderBookmark") != nil)
        let reloaded = BackupManager(defaults: defaults)
        precondition(!reloaded.needsFolderAuthorization && reloaded.needsBackup)
        precondition(reloaded.folderURL?.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        do {
            try backup.setFolder(root.appendingPathComponent("backups"), dataRoot: root)
            preconditionFailure("Accepted backup folder inside diary")
        } catch BackupError.folderInsideDiary {}
        precondition(backup.folderURL?.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        let archive = await backup.backupNow(store: store)
        precondition(archive != nil && backup.errorMessage == nil)
        precondition(backup.backups().contains { $0.resolvingSymlinksInPath() == archive!.resolvingSymlinksInPath() } && !backup.needsBackup)
        let savedCount = store.entries.count
        _ = store.createTodayEntry()
        let restored = await backup.restore(from: archive!, store: store)
        precondition(restored && store.entries.count == savedCount)
        precondition(store.entry(with: created.id)?.bodyMarkdown == "new ![](\(path))")
        for photo in store.photos() { precondition(fm.fileExists(atPath: photo.url.path)) }
        let invalidArchive = folder.appendingPathComponent("invalid.zip")
        try Data([1, 2, 3]).write(to: invalidArchive)
        let invalidRestore = await backup.restore(from: invalidArchive, store: store)
        precondition(!invalidRestore && store.entries.count == savedCount)
        print("PASS: year/month/day migration, relative images, metadata, backfill persistence, blank deletion, encryption, tombstones, repeated reload, multi-entry isolation, conflict preservation, corrupt ciphertext, legacy authorization, bookmarks, backup and restore")
    }
}
