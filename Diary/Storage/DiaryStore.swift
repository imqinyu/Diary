import CryptoKit
import AppKit
import Foundation
import Observation

/// 所有磁盘读写的唯一入口。纯文本文件是唯一事实来源，内存里的数组只是索引。
@MainActor
@Observable
final class DiaryStore {
    private(set) var entries: [DiaryEntry] = []
    private(set) var dataRoot: URL
    var errorMessage: String?
    /// 新建条目后由界面读取，用来切换选中项。
    var lastCreatedID: String?
    /// 手动插入旧日记后切换选中项（不触发自动填位置天气）。
    var lastInsertedID: String?
    /// 从相册等其它窗口请求打开某条日记。
    var requestedEntryID: String?
    /// 当天条目被彻底删除后，把列表焦点挪到还存在的条目上。
    var focusEntryID: String?
    /// 新建后等待自动填位置和天气的条目（由浏览页在开关打开时设置）。
    var pendingAutoFillID: String?
    private(set) var externalReloadGeneration = 0
    @ObservationIgnored var onDiskChange: (() -> Void)?
    static let flushEditorsNotification = Notification.Name("DiaryFlushEditorsForSync")

    func flushEditorsForSync() {
        NotificationCenter.default.post(name: Self.flushEditorsNotification, object: self)
    }

    func reloadFromSync() {
        externalReloadGeneration += 1
        ThumbnailCache.shared.clear()
        reload()
    }

    private static let rootDefaultsKey = "DiaryDataRootPath"
    private let privacy: PrivacyManager

    init(privacy: PrivacyManager? = nil) {
        self.privacy = privacy ?? PrivacyManager()
        let saved = UserDefaults.standard.string(forKey: Self.rootDefaultsKey)
        let root = saved.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultRoot()
        self.dataRoot = root
        prepareDirectories()
        reload()
    }

    /// 界面能看到的条目：锁着的时候私密条目整个消失。
    var visibleEntries: [DiaryEntry] {
        privacy.isLocked ? entries.filter { !$0.isPrivate } : entries
    }

    // MARK: - 路径

    static func defaultRoot() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent("Diary", isDirectory: true)
    }

    var entriesDirectory: URL {
        dataRoot.appendingPathComponent("entries", isDirectory: true)
    }

    private func prepareDirectories() {
        try? FileManager.default.createDirectory(at: entriesDirectory, withIntermediateDirectories: true)
    }

    func changeRoot(to url: URL) {
        flushEditorsForSync()
        dataRoot = url
        UserDefaults.standard.set(url.path, forKey: Self.rootDefaultsKey)
        prepareDirectories()
        reloadFromSync()
        onDiskChange?()
    }

    func revealInFinder() {
        prepareDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([entriesDirectory])
    }

    // MARK: - 读取

    func reload() {
        var loaded: [DiaryEntry] = []
        let key = privacy.encryptionKey
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]

        if let enumerator = fileManager.enumerator(
            at: entriesDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            // 先收集路径，再迁移，避免遍历期间移动文件导致重复或漏读。
            let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "md" }
            for url in files {
                let location: URL
                do {
                    location = try migrateEntry(at: url, key: key)
                } catch {
                    errorMessage = "整理日记目录失败，原文件已保留：\(error.localizedDescription)"
                    location = url
                }
                if let entry = loadEntry(at: location, key: key) {
                    loaded.append(entry)
                }
            }
        }

        loaded.sort { lhs, rhs in
            if lhs.dayKey != rhs.dayKey { return lhs.dayKey > rhs.dayKey }
            return lhs.sequence < rhs.sequence
        }
        entries = loaded
    }

    private func loadEntry(at url: URL, key: SymmetricKey?) -> DiaryEntry? {
        guard let document = try? EntryDocument.read(from: url) else { return nil }
        return DiaryEntry(document: document, fileURL: url, key: key,
                          keyResolver: { self.privacy.encryptionKey(for: $0) })
    }

    func entry(with id: String) -> DiaryEntry? {
        visibleEntries.first { $0.id == id }
    }

    func entries(forDay dayKey: String) -> [DiaryEntry] {
        visibleEntries.filter { $0.dayKey == dayKey }
    }

    /// 列表里显示的名字：用户没起标题就用日期，一天多页再补 #序号。
    func displayTitle(for entry: DiaryEntry) -> String {
        let custom = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if custom.isEmpty {
            let day = DayKey.display(entry.dayKey)
            base = entries(forDay: entry.dayKey).count > 1 ? "\(day)#\(entry.sequence)" : day
        } else {
            base = custom
        }
        return entry.isDeleted ? base + "（已删除）" : base
    }

    /// 所有出现过的标签，用于补全。
    var allTags: [String] {
        Set(visibleEntries.flatMap(\.tags)).sorted()
    }

    /// 相册用的图片索引。
    func photos() -> [PhotoItem] {
        photos(in: visibleEntries)
    }

    func photos(in entries: [DiaryEntry]) -> [PhotoItem] {
        var items: [PhotoItem] = []
        for entry in entries where !entry.isDeleted && !entry.bodyMarkdown.isEmpty {
            let directory = entry.fileURL.deletingLastPathComponent()
            let title = displayTitle(for: entry)
            for path in MarkdownText.imagePaths(entry.bodyMarkdown) {
                let embedded = EmbeddedImages.bytes(path)
                if path.hasPrefix("data:") && embedded == nil { continue }
                items.append(PhotoItem(
                    entryID: entry.id,
                    entryTitle: title,
                    dayKey: entry.dayKey,
                    relativePath: path,
                    url: embedded == nil ? directory.appendingPathComponent(path) : entry.fileURL,
                    data: embedded
                ))
            }
        }
        return items
    }

    // MARK: - 写入

    @discardableResult
    func createTodayEntry() -> DiaryEntry? {
        createEntry(on: DayKey.today(), createdAt: Date(), editWindow: nil)
    }

    /// 手动插入一篇以前的日记：按所选日期归档，给半天补写期，过期自动只读。
    @discardableResult
    func insertEntry(on date: Date) -> DiaryEntry? {
        createEntry(
            on: DayKey.string(from: date),
            createdAt: date,
            editWindow: Self.insertEditWindow
        )
    }

    /// 半天。写进文件的 editable_until 是绝对时间，别的平台照着读就行。
    static let insertEditWindow: TimeInterval = 12 * 60 * 60

    @discardableResult
    private func createEntry(on dayKey: String, createdAt: Date, editWindow: TimeInterval?) -> DiaryEntry? {
        let nextSequence = (entries.filter { $0.dayKey == dayKey }.map(\.sequence).max() ?? 0) + 1
        let stem = EntryFileName.stem(dayKey: dayKey, sequence: nextSequence)
        guard let directory = Self.dayDirectory(for: dayKey, under: entriesDirectory) else { return nil }

        let now = Date()
        let newEntry = DiaryEntry(
            id: stem,
            dayKey: dayKey,
            sequence: nextSequence,
            created: createdAt,
            updated: now,
            title: "",
            mood: nil,
            tags: [],
            isPrivate: false,
            isDeleted: false,
            deletedAt: nil,
            wordCount: 0,
            attachmentCount: 0,
            location: nil,
            weather: nil,
            excerpt: "",
            fileURL: directory.appendingPathComponent(stem).appendingPathExtension("md"),
            bodyMarkdown: "",
            editableUntil: editWindow.map { now.addingTimeInterval($0) },
            isBackfilled: editWindow != nil
        )

        do {
            try newEntry.makeDocument().write(to: newEntry.fileURL)
        } catch {
            errorMessage = "无法创建条目：\(error.localizedDescription)"
            return nil
        }

        reload()
        onDiskChange?()
        if editWindow == nil {
            lastCreatedID = newEntry.id
        } else {
            lastInsertedID = newEntry.id
        }
        return entry(with: newEntry.id)
    }

    func saveBody(entryID: String, markdown: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.isWritable else { return }
        guard markdown != entry.bodyMarkdown else { return }

        entry.bodyMarkdown = markdown
        entry.updated = Date()
        entry.wordCount = WordCounter.count(MarkdownText.plain(markdown))
        entry.attachmentCount = MarkdownText.imageCount(markdown)
        entry.excerpt = MarkdownText.excerpt(markdown)

        persist(entry, at: index)
    }

    func updateTitle(entryID: String, title: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.isWritable else { return }
        guard title != entry.title else { return }
        entry.title = title
        entry.updated = Date()
        persist(entry, at: index)
    }

    func updateMood(entryID: String, mood: Mood?) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.isWritable else { return }
        guard mood != entry.mood else { return }
        entry.mood = mood
        entry.updated = Date()
        persist(entry, at: index)
    }

    func updateMeta(entryID: String, location: EntryLocation?, weather: EntryWeather?) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.isWritable else { return }
        guard location != entry.location || weather != entry.weather else { return }
        entry.location = location
        entry.weather = weather
        entry.updated = Date()
        persist(entry, at: index)
    }

    func updatePrivacy(entryID: String, isPrivate: Bool) {
        flushEditorsForSync()
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard privacy.isUnlocked, !entry.isDeleted, entry.isContentAvailable else { return }
        guard isPrivate != entry.isPrivate else { return }
        entry.isPrivate = isPrivate
        if persist(entry, at: index) { reloadFromSync() }
    }

    func updateTags(entryID: String, tags: [String]) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.isWritable else { return }
        let normalized = Self.normalizeTags(tags)
        guard normalized != entry.tags else { return }
        entry.tags = normalized
        entry.updated = Date()
        persist(entry, at: index)
    }

    /// 从还能编辑的条目里彻底移除某个标签，返回改动条数。
    /// 已封存的旧日记保持原样，和「过去只读」的规则一致。
    @discardableResult
    func removeTag(_ tag: String) -> Int {
        var changed = 0
        for index in entries.indices where entries[index].tags.contains(tag) {
            guard entries[index].isWritable else { continue }
            var entry = entries[index]
            entry.tags.removeAll { $0 == tag }
            entry.updated = Date()
            if persist(entry, at: index) { changed += 1 }
        }
        return changed
    }

    /// 这个标签有多少条被固定在了已封存的旧日记里。
    func sealedEntryCount(forTag tag: String) -> Int {
        entries.filter { $0.tags.contains(tag) && !$0.isWritable }.count
    }

    /// 去掉 #、首尾空白和重复项，过长的截断。
    static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            if tag.count > 24 { tag = String(tag.prefix(24)) }
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    /// 删除分两种：
    /// 还能编辑的（当天、或插入后半天补写期内）→ 整页撕掉，文件和图片目录都不留；
    /// 已经封存的旧日记 → 留墓碑，正文清空但元数据与预览保留。
    @discardableResult
    func deleteEntry(entryID: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        let entry = entries[index]
        guard !entry.isDeleted else { return false }
        guard entry.isContentAvailable else {
            errorMessage = "请先解锁这篇加密日记后再删除"
            return false
        }

        if entry.isWritable {
            return eraseCompletely(entry, at: index)
        }
        leaveTombstone(entry, at: index)
        return false
    }

    /// 这一页删掉后是否会留下痕迹，界面上用来写不同的提示。
    func willLeaveTombstone(entryID: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return false }
        return !entry.isWritable
    }

    private func eraseCompletely(_ entry: DiaryEntry, at index: Int) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: entry.fileURL)
            try? fileManager.removeItem(at: entry.assetsDirectory)
            entries.remove(at: index)
            focusEntryID = visibleEntries.first?.id
            onDiskChange?()
            return true
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
            return false
        }
    }

    private func leaveTombstone(_ entry: DiaryEntry, at index: Int) {
        var tombstone = entry
        let preview = MarkdownText.excerpt(tombstone.bodyMarkdown)
        if !preview.isEmpty { tombstone.excerpt = preview }
        tombstone.isDeleted = true
        tombstone.deletedAt = Date()
        tombstone.updated = Date()
        tombstone.bodyMarkdown = ""
        persist(tombstone, at: index)
    }

    @discardableResult
    private func persist(_ entry: DiaryEntry, at index: Int) -> Bool {
        let key = privacy.encryptionKey
        var updated = entry
        guard !entry.isPrivate || entry.isDeleted || key != nil else {
            errorMessage = "请先解锁隐私日记"; return false
        }
        updated.isEncrypted = entry.isPrivate && !entry.isDeleted && key != nil
        updated.encryptionSalt = updated.isEncrypted ? privacy.encryptionSalt : nil
        do {
            if updated.isEncrypted { updated = try embeddedEntry(updated) }
            let document = try protectedDocument(updated, key: updated.isEncrypted ? key : nil)
            try document.write(to: updated.fileURL)
            if updated.isEncrypted {
                for url in removablePrivateAssets(updated) { try FileManager.default.removeItem(at: url) }
            }
            entries[index] = updated
            onDiskChange?()
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 加密迁移

    private func embeddedEntry(_ entry: DiaryEntry) throws -> DiaryEntry {
        var result = entry
        result.bodyMarkdown = try EmbeddedImages.embed(entry.bodyMarkdown) { path in
            guard !path.contains("://"), !path.hasPrefix("/") else { throw EmbeddedImages.Failure.unreadable(path) }
            let url = self.assetURL(relativePath: path, for: entry).resolvingSymlinksInPath()
            guard url.path.hasPrefix(self.entriesDirectory.resolvingSymlinksInPath().path + "/") else { throw EmbeddedImages.Failure.unreadable(path) }
            do { return try Data(contentsOf: url) } catch { throw EmbeddedImages.Failure.unreadable(path) }
        }
        return result
    }

    private func protectedDocument(_ entry: DiaryEntry, key: SymmetricKey?) throws -> EntryDocument {
        var document = entry.makeDocument(encryptionKey: nil)
        if let key, entry.isPrivate, !entry.isDeleted {
            guard let ciphertext = PrivacyCrypto.seal(entry.bodyMarkdown, key: key) else { throw EmbeddedImages.Failure.encryption }
            document.body = ciphertext
            document.frontMatter.set("encrypted", .scalar("true"))
            document.frontMatter.set("encryption_salt", privacy.encryptionSalt.map { .scalar($0) })
        }
        guard document.encode().utf8.count <= SyncFileStore.maximumFileSize else { throw EmbeddedImages.Failure.tooLarge }
        return document
    }

    private func removablePrivateAssets(_ entry: DiaryEntry, excluding ids: Set<String> = []) -> [URL] {
        let shared = Set(entries.filter { $0.id != entry.id && !ids.contains($0.id) && $0.isContentAvailable }.flatMap { other in
            MarkdownText.imagePaths(other.bodyMarkdown).filter { !$0.hasPrefix("data:") }.map { self.assetURL(relativePath: $0, for: other).resolvingSymlinksInPath().path }
        })
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let base = entry.assetsDirectory.resolvingSymlinksInPath().path
        guard base.hasPrefix(entriesDirectory.resolvingSymlinksInPath().path + "/"),
              (try? entry.assetsDirectory.resourceValues(forKeys: keys).isSymbolicLink) != true,
              let enumerator = FileManager.default.enumerator(at: entry.assetsDirectory, includingPropertiesForKeys: Array(keys)) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            guard let values = try? $0.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { return false }
            let path = $0.resolvingSymlinksInPath().path
            return path.hasPrefix(base + "/") && !shared.contains(path)
        }
    }

    /// Both legacy plaintext and legacy encrypted bodies migrate after unlocking.
    @discardableResult func encryptPlaintextPrivateEntries() -> Bool { rewritePrivateEntries(encrypt: true, onlyLegacy: true) }
    @discardableResult func reencryptPrivateEntries() -> Bool { rewritePrivateEntries(encrypt: true) }
    @discardableResult func decryptPrivateEntries() -> Bool { rewritePrivateEntries(encrypt: false) }

    @discardableResult func changePrivacyPassword(current: String, new: String) -> Bool {
        flushEditorsForSync()
        guard privacy.changePassword(current: current, new: new) else { errorMessage = privacy.errorMessage; return false }
        if reencryptPrivateEntries() { return true }
        // A failed directory transaction leaves the old ciphertext intact; retain its password.
        _ = privacy.changePassword(current: new, new: current)
        reloadFromSync()
        return false
    }

    private func rewritePrivateEntries(encrypt: Bool, onlyLegacy: Bool = false) -> Bool {
        let targets = entries.filter { entry in
            entry.isPrivate && !entry.isDeleted && (!onlyLegacy || !entry.isEncrypted || EmbeddedImages.needsEmbedding(entry.bodyMarkdown) || !removablePrivateAssets(entry).isEmpty)
        }
        guard !targets.isEmpty else { return true }
        guard targets.allSatisfy(\.isContentAvailable), !encrypt || privacy.encryptionKey != nil else {
            errorMessage = "请先解锁所有隐私日记"; return false
        }
        do {
            let disk = SyncFileStore(directory: dataRoot.appendingPathComponent(".privacy-work"))
            let before = try disk.scan(root: dataRoot)
            var files = before.data
            let ids = Set(targets.map(\.id))
            for entry in targets {
                var next = encrypt ? try embeddedEntry(entry) : entry
                next.isEncrypted = encrypt
                next.encryptionSalt = encrypt ? privacy.encryptionSalt : nil
                let document = try protectedDocument(next, key: encrypt ? privacy.encryptionKey : nil)
                let path = try relativeStoragePath(entry.fileURL)
                files[path] = Data(document.encode().utf8)
                if encrypt { for url in removablePrivateAssets(entry, excluding: ids) { files.removeValue(forKey: try relativeStoragePath(url)) } }
            }
            _ = try disk.apply(files: files, expected: before.hashes, root: dataRoot)
            reloadFromSync()
            onDiskChange?()
            return true
        } catch {
            errorMessage = "隐私图片迁移失败，原文件已保留：\(error.localizedDescription)"
            return false
        }
    }

    private func relativeStoragePath(_ url: URL) throws -> String {
        let root = dataRoot.resolvingSymlinksInPath().pathComponents
        let path = url.resolvingSymlinksInPath().pathComponents
        guard Array(path.prefix(root.count)) == root else { throw DiarySyncError.unsafePath(url.lastPathComponent) }
        return path.dropFirst(root.count).joined(separator: "/")
    }

    // MARK: - 图片

    /// 为本机旧版密文补齐可跨设备解密的公开参数，不上传密码或验证哈希。
    func prepareForSync() throws {
        if entries.contains(where: { $0.isPrivate && !$0.isDeleted && !$0.isContentAvailable && !removablePrivateAssets($0).isEmpty }) {
            throw EmbeddedImages.Failure.unreadable("旧隐私图片需要先解锁迁移")
        }
        if privacy.isUnlocked, !encryptPlaintextPrivateEntries() { throw EmbeddedImages.Failure.encryption }
        for index in entries.indices where entries[index].isEncrypted && entries[index].encryptionSalt == nil {
            var doc = try EntryDocument.read(from: entries[index].fileURL)
            if let salt = doc.frontMatter.string("encryption_salt") {
                entries[index].encryptionSalt = salt
                continue
            }
            guard let salt = privacy.encryptionSalt, let key = privacy.encryptionKey else {
                throw DiarySyncError.unlockLegacyEncryption
            }
            guard PrivacyCrypto.open(doc.body, key: key) != nil else {
                throw DiarySyncError.invalidEntry(entries[index].fileURL.lastPathComponent)
            }
            doc.frontMatter.set("encryption_salt", .scalar(salt))
            if doc.frontMatter.string("updated") == nil {
                doc.frontMatter.set("updated", .scalar(ISO8601.string(entries[index].updated)))
            }
            try doc.write(to: entries[index].fileURL)
            entries[index].encryptionSalt = salt
            onDiskChange?()
        }
    }

    /// 把图片复制进条目的 assets 目录，返回相对路径（相对条目文件所在目录）。
    func importImage(from sourceURL: URL, for entryID: String) -> String? {
        guard let entry = entry(with: entryID), entry.isWritable else { return nil }
        let directory = entry.assetsDirectory
        if entry.isPrivate {
            do { return try EmbeddedImages.uri(Data(contentsOf: sourceURL), extension: sourceURL.pathExtension) }
            catch { errorMessage = "无法插入图片：\(error.localizedDescription)"; return nil }
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var ext = sourceURL.pathExtension.lowercased()
            if ext.isEmpty { ext = "png" }
            let name = String(UUID().uuidString.prefix(8)).lowercased() + "." + ext
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            onDiskChange?()
            return entry.assetRelativePath(for: name)
        } catch {
            errorMessage = "无法插入图片：\(error.localizedDescription)"
            return nil
        }
    }

    /// 剪贴板里的图片没有源文件，统一保存成 PNG，正文仍只记录相对路径。
    func importImage(_ image: NSImage, for entryID: String) -> String? {
        guard let entry = entry(with: entryID), entry.isWritable else { return nil }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            errorMessage = "无法读取剪贴板中的图片"
            return nil
        }
        if entry.isPrivate {
            do { return try EmbeddedImages.uri(data, extension: "png") }
            catch { errorMessage = "无法插入图片：\(error.localizedDescription)"; return nil }
        }
        let directory = entry.assetsDirectory
        let name = UUID().uuidString.lowercased() + ".png"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            onDiskChange?()
            return entry.assetRelativePath(for: name)
        } catch {
            errorMessage = "无法插入图片：\(error.localizedDescription)"
            return nil
        }
    }

    func assetURL(relativePath: String, for entry: DiaryEntry) -> URL {
        entry.fileURL.deletingLastPathComponent().appendingPathComponent(relativePath)
    }
}

// MARK: - 目录划分

extension DiaryStore {
    /// `entries/2026/11/14/2026-11-14-1.md`，同一天的 Markdown 与 assets 放在一起。
    static func dayDirectory(for dayKey: String, under root: URL) -> URL? {
        guard let date = DayKey.date(from: dayKey), DayKey.string(from: date) == dayKey else { return nil }
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }

    /// 复制成功并写好新 Markdown 后才删除旧文件；加密正文在解锁后再迁移。
    private func migrateEntry(at source: URL, key: SymmetricKey?) throws -> URL {
        var document = try EntryDocument.read(from: source)
        guard let entry = DiaryEntry(document: document, fileURL: source, key: key),
              let day = Self.dayDirectory(for: entry.dayKey, under: entriesDirectory) else { return source }
        let destination = day.appendingPathComponent(source.lastPathComponent)
        guard destination.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() else { return source }
        // 迁移会改变文件的磁盘修改时间，先固定从旧文件推断出来的补写状态。
        document.frontMatter.set("backfilled", .scalar(entry.isBackfilled ? "true" : "false"))
        if document.frontMatter.string("updated") == nil {
            document.frontMatter.set("updated", .scalar(ISO8601.string(entry.updated)))
        }
        if document.frontMatter.string("created") == nil {
            document.frontMatter.set("created", .scalar(ISO8601.string(entry.created)))
        }

        let oldAssets = source.deletingPathExtension().appendingPathExtension("assets")
        let newAssets = day.appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(entry.stem, isDirectory: true)
        let oldPrefix = oldAssets.lastPathComponent + "/"
        let newPrefix = "assets/\(entry.stem)/"
        var body = document.body
        let key = privacy.encryptionKey(for: document.frontMatter.string("encryption_salt"))
        if entry.isEncrypted {
            guard let key, let plaintext = PrivacyCrypto.open(body, key: key) else { return source }
            body = plaintext
        }
        body = body.replacingOccurrences(of: "](\(oldPrefix)", with: "](\(newPrefix)")
        // 手动添加的其它相对图片路径仍指向原文件，不因 Markdown 移动而失效。
        let imagePattern = try NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(([^)]+)\\)")
        let matches = imagePattern.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
        // 从后往前替换原始匹配，避免新路径与另一个旧路径相同时被再次改写。
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: body) else { continue }
            let path = String(body[range])
            guard !path.hasPrefix(newPrefix), !path.hasPrefix("/"), URL(string: path)?.scheme == nil else { continue }
            let image = source.deletingLastPathComponent().appendingPathComponent(path).resolvingSymlinksInPath()
            let baseParts = day.resolvingSymlinksInPath().pathComponents
            let imageParts = image.pathComponents
            var common = 0
            while common < min(baseParts.count, imageParts.count), baseParts[common] == imageParts[common] { common += 1 }
            let relative = (Array(repeating: "..", count: baseParts.count - common) + imageParts.dropFirst(common)).joined(separator: "/")
            body.replaceSubrange(range, with: relative)
        }
        if entry.isEncrypted {
            guard let key, let encrypted = PrivacyCrypto.seal(body, key: key) else { return source }
            document.body = encrypted
        } else {
            document.body = body
        }

        let manager = FileManager.default
        // 不覆盖同名日记或图片目录，冲突时继续从原位置读取。
        guard !manager.fileExists(atPath: destination.path), !manager.fileExists(atPath: newAssets.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let staging = day.appendingPathComponent(".migration-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let stagedFile = staging.appendingPathComponent(source.lastPathComponent)
        let stagedAssets = staging.appendingPathComponent("assets", isDirectory: true)
        let hasAssets = manager.fileExists(atPath: oldAssets.path)
        if hasAssets { try manager.copyItem(at: oldAssets, to: stagedAssets) }
        try document.write(to: stagedFile)
        var installedAssets = false
        var installedFile = false
        do {
            if hasAssets {
                try manager.createDirectory(at: newAssets.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: stagedAssets, to: newAssets)
                installedAssets = true
            }
            try manager.moveItem(at: stagedFile, to: destination)
            installedFile = true
            try manager.removeItem(at: source)
        } catch {
            if installedFile { try? manager.removeItem(at: destination) }
            if installedAssets { try? manager.removeItem(at: newAssets) }
            throw error
        }
        if hasAssets { try? manager.removeItem(at: oldAssets) }
        onDiskChange?()
        return destination
    }
}
