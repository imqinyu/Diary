import Foundation

/// 一次解锁尝试。只记时间、方式、成没成，不记密码本身。
struct PrivacyAuditEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date
    /// "密码" / "密码 + 触控 ID" / "密码通过 · 触控 ID 未通过"
    var method: String
    var success: Bool
}

/// 访问记录存在应用支持目录，不往日记目录里塞东西。
/// 记录只增不减，用户不能清除——这正是它该有的样子。
@MainActor
final class PrivacyAuditLog {
    private(set) var entries: [PrivacyAuditEntry] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Diary", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("privacy-audit.json")
    }

    func record(method: String, success: Bool, date: Date = Date()) {
        entries.append(PrivacyAuditEntry(date: date, method: method, success: success))
        save()
    }

    /// 按时间倒序，只留指定天数内的；days 为 nil 表示全部。
    func recent(days: Int?, now: Date = Date()) -> [PrivacyAuditEntry] {
        let sorted = entries.sorted { $0.date > $1.date }
        guard let days,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return sorted
        }
        return sorted.filter { $0.date >= cutoff }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PrivacyAuditEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
