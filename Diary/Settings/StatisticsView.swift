import SwiftUI

/// 设置里的统计页：把攒下来的日子换算成几个能一眼看懂的数。
struct StatisticsView: View {
    @Environment(DiaryStore.self) private var store

    private var stats: DiaryStatistics {
        StatisticsCalculator.compute(entries: store.visibleEntries)
    }

    var body: some View {
        let value = stats

        SettingsForm {
            SettingsSection("总览") {
                row("日记", "\(value.totalEntries) 篇")
                row("记录天数", "\(value.recordedDays) 天")
                if let first = value.firstDay, let last = value.lastDay {
                    row("时间跨度", spanText(first, last))
                }
                row("总字数", "\(value.totalWords) 字")
                row("平均每篇", "\(value.averageWords) 字")
                row("中位数", "\(value.medianWords) 字")
            }

            if value.longestWords > 0 || value.busiestMonthKey != nil || value.wordiestMonthKey != nil
                || value.busiestDayCount > 1 || value.busiestWeekday != nil || value.hourlyPeak != nil {
                SettingsSection("极值") {
                    if value.longestWords > 0, let day = value.longestDay {
                        row("最长的一篇", "\(shortDay(day)) · \(value.longestWords) 字")
                    }
                    if let month = value.busiestMonthKey {
                        row("写得最多的月份", "\(monthLabel(month)) · \(value.busiestMonthCount) 篇")
                    }
                    if let month = value.wordiestMonthKey {
                        row("字数最多的月份", "\(monthLabel(month)) · \(value.wordiestMonthWords) 字")
                    }
                    if let day = value.busiestDayKey, value.busiestDayCount > 1 {
                        row("一天写最多", "\(shortDay(day)) · \(value.busiestDayCount) 篇")
                    }
                    if let weekday = value.busiestWeekday {
                        row("最常动笔", "\(weekdayName(weekday)) · \(value.busiestWeekdayCount) 次")
                    }
                    if let hour = value.hourlyPeak {
                        row("最常写的时间", "\(hour) 点前后")
                    }
                }
            }

            SettingsSection("连续记录") {
                row("当前连续", "\(value.currentStreak) 天")
                row("最长连续", "\(value.longestStreak) 天")
            }

            if !value.monthlyCounts.isEmpty {
                SettingsSection("最近 12 个月") {
                    MonthlyBarChart(items: value.monthlyCounts)
                        .padding(.vertical, 4)
                }
            }

            if !value.moodCounts.isEmpty {
                SettingsSection("心情") {
                    ForEach(value.moodCounts, id: \.mood) { item in
                        HStack(spacing: 8) {
                            Label(item.mood.displayName, systemImage: item.mood.symbolName)
                                .foregroundStyle(item.mood.tint)
                                .font(.callout)
                            Spacer(minLength: 8)
                            Bar(value: item.count, upperBound: value.moodCounts.first?.count ?? 1)
                                .frame(width: 90)
                            Text(verbatim: "\(item.count)")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !value.topTags.isEmpty {
                SettingsSection("常用标签") {
                    ForEach(value.topTags, id: \.tag) { item in
                        HStack(spacing: 8) {
                            Text("#\(item.tag)")
                                .font(.callout)
                            Spacer(minLength: 8)
                            Bar(value: item.count, upperBound: value.topTags.first?.count ?? 1)
                                .frame(width: 90)
                            Text(verbatim: "\(item.count)")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SettingsSection("其它") {
                row("图片", "\(value.totalImages) 张")
                row("带位置", "\(value.entriesWithLocation) 篇")
                row("带天气", "\(value.entriesWithWeather) 篇")
                row("今年 / 去年", "\(value.thisYearCount) / \(value.lastYearCount) 篇")
                if value.privateEntries > 0 {
                    row("标记为隐私", "\(value.privateEntries) 篇")
                }
                if value.deletedEntries > 0 {
                    row("已删除", "\(value.deletedEntries) 篇")
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// 同一年只写一次年份，跨年两边都写，读起来才对得上。
    private func spanText(_ first: String, _ last: String) -> String {
        let firstYear = first.prefix(4)
        let lastYear = last.prefix(4)
        if firstYear == lastYear {
            return "\(fullDay(first)) — \(shortDay(last))"
        }
        return "\(fullDay(first)) — \(fullDay(last))"
    }

    private func fullDay(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return dayKey
        }
        return "\(year) 年 \(month) 月 \(day) 日"
    }

    private func shortDay(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), let day = Int(parts[2]) else { return dayKey }
        return "\(month) 月 \(day) 日"
    }

    private func monthLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return key }
        let current = Calendar.current.component(.year, from: Date())
        return year == current ? "\(month) 月" : "\(year) 年 \(month) 月"
    }

    private func weekdayName(_ weekday: Int) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = max(0, min(6, weekday - 1))
        return names[index]
    }
}

private struct Bar: View {
    let value: Int
    let upperBound: Int

    var body: some View {
        GeometryReader { proxy in
            let ratio = upperBound > 0 ? CGFloat(value) / CGFloat(upperBound) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule()
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: max(4, proxy.size.width * ratio))
            }
        }
        .frame(height: 6)
    }
}

private struct MonthlyBarChart: View {
    let items: [(key: String, count: Int, words: Int)]

    private var peak: Int {
        max(items.map(\.count).max() ?? 1, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(items, id: \.key) { item in
                VStack(spacing: 4) {
                    Text(verbatim: item.count > 0 ? "\(item.count)" : "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(item.count > 0 ? 0.65 : 0.12))
                        .frame(height: max(3, CGFloat(item.count) / CGFloat(peak) * 64))
                    Text(verbatim: monthTick(item.key))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 96, alignment: .bottom)
    }

    private func monthTick(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return key }
        return "\(month)"
    }
}
