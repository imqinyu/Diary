import Foundation

/// 一堆能从日记里算出来、但平时懒得自己数的事。
struct DiaryStatistics {
    var totalEntries = 0
    var deletedEntries = 0
    var privateEntries = 0
    var recordedDays = 0
    var firstDay: String?
    var lastDay: String?
    var totalWords = 0
    var averageWords = 0
    var longestWords = 0
    var longestDay: String?
    var medianWords = 0

    var busiestMonthKey: String?
    var busiestMonthCount = 0
    var wordiestMonthKey: String?
    var wordiestMonthWords = 0

    var busiestWeekday: Int?
    var busiestWeekdayCount = 0
    var busiestDayKey: String?
    var busiestDayCount = 0

    var currentStreak = 0
    var longestStreak = 0

    var totalImages = 0
    var entriesWithLocation = 0
    var entriesWithWeather = 0

    var moodCounts: [(mood: Mood, count: Int)] = []
    var topTags: [(tag: String, count: Int)] = []
    var hourlyPeak: Int?
    var hourlyCounts: [Int] = Array(repeating: 0, count: 24)
    var monthlyCounts: [(key: String, count: Int, words: Int)] = []
    var thisYearCount = 0
    var lastYearCount = 0
}

enum StatisticsCalculator {

    static func compute(
        entries: [DiaryEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DiaryStatistics {
        var stats = DiaryStatistics()

        let live = entries.filter { !$0.isDeleted }
        stats.totalEntries = live.count
        stats.deletedEntries = entries.filter(\.isDeleted).count
        stats.privateEntries = live.filter(\.isPrivate).count

        let dayKeys = Set(live.map(\.dayKey)).sorted()
        stats.recordedDays = dayKeys.count
        stats.firstDay = dayKeys.first
        stats.lastDay = dayKeys.last

        let words = live.map(\.wordCount)
        stats.totalWords = words.reduce(0, +)
        stats.averageWords = live.isEmpty ? 0 : stats.totalWords / live.count
        stats.medianWords = median(words.sorted())

        if let longest = live.max(by: { $0.wordCount < $1.wordCount }) {
            stats.longestWords = longest.wordCount
            stats.longestDay = longest.dayKey
        }

        // 月份统计
        var wordsByMonth: [String: Int] = [:]
        var countByMonth: [String: Int] = [:]
        for entry in live {
            let key = String(entry.dayKey.prefix(7))
            countByMonth[key, default: 0] += 1
            wordsByMonth[key, default: 0] += entry.wordCount
        }
        if let top = countByMonth.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) {
            stats.busiestMonthKey = top.key
            stats.busiestMonthCount = top.value
        }
        if let top = wordsByMonth.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) {
            stats.wordiestMonthKey = top.key
            stats.wordiestMonthWords = top.value
        }

        // 星期
        var weekdayCounts: [Int: Int] = [:]
        for dayKey in dayKeys {
            guard let date = DayKey.date(from: dayKey) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            weekdayCounts[weekday, default: 0] += 1
        }
        if let top = weekdayCounts.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) {
            stats.busiestWeekday = top.key
            stats.busiestWeekdayCount = top.value
        }

        // 单日最多
        var perDay: [String: Int] = [:]
        for entry in live { perDay[entry.dayKey, default: 0] += 1 }
        if let top = perDay.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) {
            stats.busiestDayKey = top.key
            stats.busiestDayCount = top.value
        }

        // 连续天数
        let dates = dayKeys.compactMap { DayKey.date(from: $0) }.sorted()
        stats.longestStreak = longestStreak(dates: dates, calendar: calendar)
        stats.currentStreak = currentStreak(dates: dates, now: now, calendar: calendar)

        stats.totalImages = live.map(\.attachmentCount).reduce(0, +)
        stats.entriesWithLocation = live.filter { $0.location != nil }.count
        stats.entriesWithWeather = live.filter { $0.weather != nil }.count

        var moodCounts: [Mood: Int] = [:]
        for entry in live {
            if let mood = entry.mood { moodCounts[mood, default: 0] += 1 }
        }
        stats.moodCounts = moodCounts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
            }
            .map { (mood: $0.key, count: $0.value) }

        var tagCounts: [String: Int] = [:]
        for entry in live {
            for tag in entry.tags { tagCounts[tag, default: 0] += 1 }
        }
        stats.topTags = tagCounts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(6)
            .map { (tag: $0.key, count: $0.value) }

        // 习惯在几点写
        for entry in live {
            let hour = calendar.component(.hour, from: entry.created)
            stats.hourlyCounts[hour] += 1
        }
        if let peak = stats.hourlyCounts.enumerated().max(by: { $0.element < $1.element }),
           peak.element > 0 {
            stats.hourlyPeak = peak.offset
        }

        // 最近 12 个月
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy-MM"
        var months: [(String, Int, Int)] = []
        var cursor = now
        for _ in 0..<12 {
            let key = monthFormatter.string(from: cursor)
            months.append((key, countByMonth[key] ?? 0, wordsByMonth[key] ?? 0))
            guard let previous = calendar.date(byAdding: .month, value: -1, to: cursor) else { break }
            cursor = previous
        }
        stats.monthlyCounts = months.reversed().map { (key: $0.0, count: $0.1, words: $0.2) }

        let thisYear = calendar.component(.year, from: now)
        stats.thisYearCount = live.filter { $0.dayKey.hasPrefix(String(thisYear)) }.count
        stats.lastYearCount = live.filter { $0.dayKey.hasPrefix(String(thisYear - 1)) }.count

        return stats
    }

    // MARK: - 辅助

    private static func median(_ sorted: [Int]) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func longestStreak(dates: [Date], calendar: Calendar) -> Int {
        guard !dates.isEmpty else { return 0 }
        var best = 1
        var current = 1
        for index in 1..<dates.count {
            let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: dates[index - 1]),
                                              to: calendar.startOfDay(for: dates[index])).day ?? 0
            if gap == 1 {
                current += 1
                best = max(best, current)
            } else if gap > 1 {
                current = 1
            }
        }
        return best
    }

    private static func currentStreak(dates: [Date], now: Date, calendar: Calendar) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now)
        // 今天还没写不算断，从昨天接着数
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
