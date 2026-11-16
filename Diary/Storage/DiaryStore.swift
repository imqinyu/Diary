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
        dataRoot = url
        UserDefaults.standard.set(url.path, forKey: Self.rootDefaultsKey)
        prepareDirectories()
        reload()
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
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "md" else { continue }
                if let entry = Self.loadEntry(at: url, key: key) {
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

    private static func loadEntry(at url: URL, key: SymmetricKey?) -> DiaryEntry? {
        guard let document = try? EntryDocument.read(from: url) else { return nil }
        return DiaryEntry(document: document, fileURL: url, key: key)
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
                guard !path.hasPrefix("data:") else { continue }
                items.append(PhotoItem(
                    entryID: entry.id,
                    entryTitle: title,
                    dayKey: entry.dayKey,
                    relativePath: path,
                    url: directory.appendingPathComponent(path)
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
        guard let directory = Self.monthDirectory(for: dayKey, under: entriesDirectory) else { return nil }

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
            editableUntil: editWindow.map { now.addingTimeInterval($0) }
        )

        do {
            try newEntry.makeDocument().write(to: newEntry.fileURL)
        } catch {
            errorMessage = "无法创建条目：\(error.localizedDescription)"
            return nil
        }

        reload()
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
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.isWritable else { return }
        guard isPrivate != entry.isPrivate else { return }
        entry.isPrivate = isPrivate
        entry.updated = Date()
        persist(entry, at: index)
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
            do {
                try entry.makeDocument().write(to: entry.fileURL)
                entries[index] = entry
                changed += 1
            } catch {
                errorMessage = "保存失败：\(error.localizedDescription)"
            }
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

    private func persist(_ entry: DiaryEntry, at index: Int) {
        let key = privacy.encryptionKey
        var updated = entry
        updated.isEncrypted = entry.isPrivate && !entry.isDeleted && key != nil
        do {
            try updated.makeDocument(encryptionKey: key).write(to: updated.fileURL)
            entries[index] = updated
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 加密迁移

    /// 解锁后把还停留在明文的私密条目就地加密。
    func encryptPlaintextPrivateEntries() {
        guard let key = privacy.encryptionKey else { return }
        for index in entries.indices where entries[index].isPrivate && !entries[index].isEncrypted {
            var entry = entries[index]
            entry.isEncrypted = true
            do {
                try entry.makeDocument(encryptionKey: key).write(to: entry.fileURL)
                entries[index] = entry
            } catch {
                errorMessage = "加密失败：\(error.localizedDescription)"
            }
        }
    }

    /// 改密码后，用新密钥把私密条目整体重写一遍。
    func reencryptPrivateEntries() {
        guard let key = privacy.encryptionKey else { return }
        for index in entries.indices where entries[index].isPrivate {
            var entry = entries[index]
            entry.isEncrypted = !entry.isDeleted
            do {
                try entry.makeDocument(encryptionKey: key).write(to: entry.fileURL)
                entries[index] = entry
            } catch {
                errorMessage = "重新加密失败：\(error.localizedDescription)"
            }
        }
    }

    /// 关闭隐私保护时先把内容解回明文，否则密码一删内容就永远打不开了。
    func decryptPrivateEntries() {
        for index in entries.indices where entries[index].isEncrypted {
            var entry = entries[index]
            entry.isEncrypted = false
            do {
                try entry.makeDocument(encryptionKey: nil).write(to: entry.fileURL)
                entries[index] = entry
            } catch {
                errorMessage = "解密失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 图片

    /// 把图片复制进条目的 assets 目录，返回相对路径（相对条目文件所在目录）。
    func importImage(from sourceURL: URL, for entryID: String) -> String? {
        guard let entry = entry(with: entryID) else { return nil }
        let directory = entry.assetsDirectory

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var ext = sourceURL.pathExtension.lowercased()
            if ext.isEmpty { ext = "png" }
            let name = String(UUID().uuidString.prefix(8)).lowercased() + "." + ext
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return "\(directory.lastPathComponent)/\(name)"
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
    /// `entries/2026/2026-11-14-1.md`，按月分年归档，条目多了也不会有超大目录。
    static func monthDirectory(for dayKey: String, under root: URL) -> URL? {
        let year = String(dayKey.prefix(4))
        guard year.count == 4, Int(year) != nil else { return nil }
        return root.appendingPathComponent(year, isDirectory: true)
    }
}
