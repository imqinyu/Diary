import Foundation

/// 时间筛选。除了「全部 / 今天」，其余都是用户自己挑的具体年份、月份、周次，
/// 而不是「本月 / 今年」这种跟着系统时间走的范围。
enum TimeFilter: Equatable, Hashable {
    case all
    case today
    case year(Int)
    case month(year: Int, month: Int)
    case week(year: Int, week: Int)

    /// 周的算法固定用 ISO（周一为一周开始），避免跟随系统区域设置漂移。
    static let isoCalendar = Calendar(identifier: .iso8601)

    func matches(dayKey: String) -> Bool {
        guard self != .all else { return true }
        guard let date = DayKey.date(from: dayKey) else { return false }

        switch self {
        case .all:
            return true
        case .today:
            return dayKey == DayKey.today()
        case .year(let year):
            return Calendar.current.component(.year, from: date) == year
        case .month(let year, let month):
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            return components.year == year && components.month == month
        case .week(let year, let week):
            let components = Self.isoCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return components.yearForWeekOfYear == year && components.weekOfYear == week
        }
    }

    // MARK: - 展示

    var year: Int? {
        switch self {
        case .year(let year), .month(let year, _), .week(let year, _): return year
        case .all, .today: return nil
        }
    }

    var title: String? {
        switch self {
        case .all: return "全部"
        case .today: return "今天"
        case .year(let year): return "\(year) 年"
        case .month(let year, let month): return "\(year) 年 \(month) 月"
        case .week(let year, let week): return "\(year) 年第 \(week) 周"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .today: return "\(Calendar.current.component(.day, from: Date())).calendar"
        case .year: return "calendar.circle"
        case .month: return "calendar"
        case .week: return "calendar.badge.clock"
        }
    }

    // MARK: - 周次换算

    static func weekRange(year: Int, week: Int) -> (start: Date, end: Date)? {
        var components = DateComponents()
        components.yearForWeekOfYear = year
        components.weekOfYear = week
        components.weekday = 2 // ISO 里 2 = 周一
        guard let start = isoCalendar.date(from: components) else { return nil }
        let end = isoCalendar.date(byAdding: .day, value: 6, to: start) ?? start
        return (start, end)
    }

    /// 真正有日记、且已经开始的月份。空的月和未来的月都不列出来。
    static func monthsWithEntries(in year: Int, from entries: [DiaryEntry], now: Date = Date()) -> [Int] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        var months = Set<Int>()
        for entry in entries {
            let parts = entry.dayKey.split(separator: "-")
            guard parts.count == 3,
                  let entryYear = Int(parts[0]),
                  let month = Int(parts[1]),
                  entryYear == year else { continue }
            if year > currentYear || (year == currentYear && month > currentMonth) { continue }
            months.insert(month)
        }
        return months.sorted()
    }

    /// 真正有日记、且已经开始的周。空的周和未来的周都不列出来。
    static func weeksWithEntries(in year: Int, from entries: [DiaryEntry], now: Date = Date()) -> [Int] {
        var weeks = Set<Int>()
        for entry in entries {
            guard let date = DayKey.date(from: entry.dayKey) else { continue }
            let components = isoCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            guard components.yearForWeekOfYear == year,
                  let week = components.weekOfYear else { continue }
            if let start = weekRange(year: year, week: week)?.start, start > now {
                continue
            }
            weeks.insert(week)
        }
        return weeks.sorted()
    }

    /// 某一年按 ISO 算法有几周（52 或 53）。
    static func weeksInYear(_ year: Int) -> [Int] {
        var components = DateComponents()
        components.yearForWeekOfYear = year
        components.weekOfYear = 1
        components.weekday = 2
        guard let firstWeek = isoCalendar.date(from: components),
              let range = isoCalendar.range(of: .weekOfYear, in: .yearForWeekOfYear, for: firstWeek) else {
            return Array(1...52)
        }
        return Array(range)
    }

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static func weekLabel(year: Int, week: Int) -> String {
        guard let range = weekRange(year: year, week: week) else { return "第 \(week) 周" }
        return "第 \(week) 周 · \(shortDayFormatter.string(from: range.start))–\(shortDayFormatter.string(from: range.end))"
    }
}

enum AttachmentFilter: String, CaseIterable, Identifiable {
    case any
    case withImages
    case withoutImages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "不限"
        case .withImages: return "图文"
        case .withoutImages: return "纯文本"
        }
    }

    var symbol: String {
        switch self {
        case .any: return "paperclip"
        case .withImages: return "photo"
        case .withoutImages: return "text.alignleft"
        }
    }

    func matches(_ entry: DiaryEntry) -> Bool {
        switch self {
        case .any: return true
        case .withImages: return entry.attachmentCount > 0
        case .withoutImages: return entry.attachmentCount == 0
        }
    }
}

/// 浏览页的筛选状态。多个条件之间是「与」的关系。
struct EntryFilter: Equatable {
    enum Facet {
        case time, mood, tag, type, province, city, weather
    }

    var time: TimeFilter = .all
    var mood: Mood?
    var tag: String?
    var attachments: AttachmentFilter = .any
    var locationProvince: String?
    var locationCity: String?
    var weatherText: String?
    /// 只看隐私条目。仅在解锁状态下由界面提供。
    var privateOnly = false
    var backfilledOnly = false

    var isActive: Bool {
        time != .all || mood != nil || tag != nil || attachments != .any
            || locationProvince != nil || locationCity != nil || weatherText != nil
            || privateOnly || backfilledOnly
    }

    var isAllSelected: Bool { !isActive }

    /// 一组的候选数量保留其它条件，忽略本组条件，方便直接切换选项。
    func excluding(_ facet: Facet) -> EntryFilter {
        var result = self
        switch facet {
        case .time: result.time = .all
        case .mood: result.mood = nil
        case .tag: result.tag = nil
        case .type:
            result.attachments = .any
            result.privateOnly = false
            result.backfilledOnly = false
        case .province:
            result.locationProvince = nil
            result.locationCity = nil
        case .city: result.locationCity = nil
        case .weather: result.weatherText = nil
        }
        return result
    }

    func entries(in entries: [DiaryEntry], excluding facet: Facet) -> [DiaryEntry] {
        entries.filter(excluding(facet).matches)
    }

    func matches(_ entry: DiaryEntry) -> Bool {
        guard time.matches(dayKey: entry.dayKey) else { return false }
        if let mood, entry.mood != mood { return false }
        if let tag, !entry.tags.contains(tag) { return false }
        guard attachments.matches(entry) else { return false }
        if let locationProvince, entry.location?.provinceForFilter != locationProvince { return false }
        if let locationCity, entry.location?.city != locationCity { return false }
        if let weatherText, entry.weather?.text != weatherText { return false }
        if privateOnly, !entry.isPrivate { return false }
        if backfilledOnly, !entry.isBackfilled { return false }
        return true
    }
}
