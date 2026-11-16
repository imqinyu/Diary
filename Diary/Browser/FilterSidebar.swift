import SwiftUI

struct FilterSidebar: View {
    @Binding var filter: EntryFilter
    /// 搜索后的可见条目；各筛选组再叠加其它组的条件。
    let entries: [DiaryEntry]
    @Environment(DiaryStore.self) private var store
    @Environment(PrivacyManager.self) private var privacy
    @Environment(AppPreferences.self) private var preferences

    @State private var pendingTagDelete: String?
    @State private var todaySymbol = TimeFilter.today.symbol

    // macOS 的 sidebar List 会覆盖环境强调色，选中背景直接使用用户偏好。
    private var accent: Color { preferences.themeColor.color ?? .accentColor }

    var body: some View {
        List {
            Section("时间") {
                // 「全部」也是清空筛选的入口，即使没有匹配条目也始终保留。
                timeButton(.all, title: "全部", symbol: "tray.full")
                if count(for: .today) > 0 {
                    timeButton(.today, title: "今天", symbol: todaySymbol)
                }

                if !availableYears.isEmpty && (!isYearSelected || count(for: filter.time) > 0) {
                    yearMenu
                }
                if availableYears.contains(where: { !monthsWithEntries(in: $0).isEmpty })
                    && (!isMonthSelected || count(for: filter.time) > 0) {
                    monthMenu
                }
                if availableWeekYears.contains(where: { !weeksWithEntries(in: $0).isEmpty })
                    && (!isWeekSelected || count(for: filter.time) > 0) {
                    weekMenu
                }
            }

            if count(for: .withImages) > 0 || count(for: .withoutImages) > 0
                || backfilledCount > 0 || (privacy.isUnlocked && privateCount > 0) {
                Section("类型") {
                    if count(for: .withImages) > 0 {
                        attachmentRow(.withImages)
                    }
                    if count(for: .withoutImages) > 0 {
                        attachmentRow(.withoutImages)
                    }
                    if backfilledCount > 0 {
                        backfilledRow
                    }
                    // 锁着的时候连这个入口都不出现，免得旁人看出有隐藏内容
                    if privacy.isUnlocked && privateCount > 0 {
                        privateRow
                    }
                }
            }

            if !moodCounts.isEmpty {
                Section("心情") {
                    ForEach(Mood.allCases) { mood in
                        if let count = moodCounts[mood] {
                            row(
                                title: mood.displayName,
                                symbol: mood.symbolName,
                                count: count,
                                isSelected: filter.mood == mood,
                                tint: mood.tint
                            ) {
                                filter.mood = filter.mood == mood ? nil : mood
                            }
                        }
                    }
                }
            }

            if showsMenu(provinceCounts, selected: filter.locationProvince)
                || showsMenu(cityCounts, selected: filter.locationCity) {
                Section("地点") {
                    if showsMenu(provinceCounts, selected: filter.locationProvince) {
                        provinceMenu
                    }
                    if showsMenu(cityCounts, selected: filter.locationCity) {
                        cityMenu
                    }
                }
            }

            // 标签和天气条目可能很多，做成和「地点」一样的下拉菜单，
            // 侧边栏长度就固定了，交互也和其它分组一致。
            if showsMenu(tagCounts, selected: filter.tag) || showsMenu(weatherCounts, selected: filter.weatherText) {
                Section("元数据") {
                    if showsMenu(tagCounts, selected: filter.tag) {
                        tagMenu
                    }
                    if showsMenu(weatherCounts, selected: filter.weatherText) {
                        weatherMenu
                    }
                }
            }

        }
        .listStyle(.sidebar)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            todaySymbol = TimeFilter.today.symbol
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            todaySymbol = TimeFilter.today.symbol
        }
        .confirmationDialog(
            "移除标签「#\(pendingTagDelete ?? "")」？",
            isPresented: Binding(
                get: { pendingTagDelete != nil },
                set: { if !$0 { pendingTagDelete = nil } }
            )
        ) {
            Button("移除", role: .destructive) { confirmTagDelete() }
            Button("取消", role: .cancel) { pendingTagDelete = nil }
        } message: {
            Text(tagDeleteMessage)
        }
    }

    private func confirmTagDelete() {
        guard let tag = pendingTagDelete else { return }
        store.removeTag(tag)
        if filter.tag == tag { filter.tag = nil }
        pendingTagDelete = nil
    }

    private var tagDeleteMessage: String {
        guard let tag = pendingTagDelete else { return "" }
        let sealed = store.sealedEntryCount(forTag: tag)
        if sealed > 0 {
            return "会从还能编辑的日记里移除，另有 \(sealed) 篇已封存的旧日记保持不变。"
        }
        return "会从所有日记里移除这个标签。"
    }

    private var tagMenu: some View {
        let selected = filter.tag
        let isSelected = selected != nil
        return Menu {
            Button("不限标签") { filter.tag = nil }
            Divider()
            ForEach(tagCounts) { item in
                Button {
                    filter.tag = selected == item.name ? nil : item.name
                } label: {
                    Text(verbatim: "\(item.name) · \(item.count)")
                }
            }
        } label: {
            rowLabel(
                title: selected ?? "标签",
                symbol: "number",
                count: selected.flatMap { name in tagCounts.first { $0.name == name }?.count },
                isSelected: isSelected,
                showsMenuHint: true
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
        .contextMenu {
            if let selected {
                Button("从所有日记移除「#\(selected)」…", role: .destructive) {
                    pendingTagDelete = selected
                }
            }
        }
    }

    private var weatherMenu: some View {
        let selected = filter.weatherText
        let isSelected = selected != nil
        return Menu {
            Button("不限天气") { filter.weatherText = nil }
            Divider()
            ForEach(weatherCounts) { item in
                Button {
                    filter.weatherText = selected == item.name ? nil : item.name
                } label: {
                    Text(verbatim: "\(item.name) · \(item.count)")
                }
            }
        } label: {
            rowLabel(
                title: selected ?? "天气",
                symbol: "cloud.sun",
                count: selected.flatMap { name in weatherCounts.first { $0.name == name }?.count },
                isSelected: isSelected,
                showsMenuHint: true
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    private var isYearSelected: Bool {
        if case .year = filter.time { return true }
        return false
    }

    private var isMonthSelected: Bool {
        if case .month = filter.time { return true }
        return false
    }

    private var isWeekSelected: Bool {
        if case .week = filter.time { return true }
        return false
    }

    private var yearMenu: some View {
        let isSelected = isYearSelected
        return Menu {
            Button("不限时间") { filter.time = .all }
            Divider()
            ForEach(availableYears, id: \.self) { year in
                Button { filter.time = isSelected && filter.time == .year(year) ? .all : .year(year) } label: {
                    Text(verbatim: "\(year) 年 · \(count(for: .year(year)))")
                }
            }
        } label: {
            rowLabel(
                title: isSelected ? (filter.time.title ?? "年份") : "年份",
                symbol: "calendar.circle",
                count: isSelected ? count(for: filter.time) : nil,
                isSelected: isSelected,
                showsMenuHint: true
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    private var monthMenu: some View {
        let isSelected = isMonthSelected
        return Menu {
            Button("不限时间") { filter.time = .all }
            Divider()
            ForEach(availableYears, id: \.self) { year in
                let months = monthsWithEntries(in: year)
                if !months.isEmpty {
                    Menu {
                        ForEach(months, id: \.self) { month in
                            Button {
                                let time = TimeFilter.month(year: year, month: month)
                                filter.time = filter.time == time ? .all : time
                            } label: {
                                Text(verbatim: "\(month) 月 · \(count(for: .month(year: year, month: month)))")
                            }
                        }
                    } label: {
                        Text(verbatim: "\(year) 年 · \(months.count) 个月")
                    }
                }
            }
        } label: {
            rowLabel(
                title: isSelected ? (filter.time.title ?? "月份") : "月份",
                symbol: "calendar",
                count: isSelected ? count(for: filter.time) : nil,
                isSelected: isSelected,
                showsMenuHint: true
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    private var weekMenu: some View {
        let isSelected = isWeekSelected
        return Menu {
            Button("不限时间") { filter.time = .all }
            Divider()
            ForEach(availableWeekYears, id: \.self) { year in
                let weeks = weeksWithEntries(in: year)
                if !weeks.isEmpty {
                    Menu {
                        ForEach(weeks, id: \.self) { week in
                            Button("\(TimeFilter.weekLabel(year: year, week: week)) · \(count(for: .week(year: year, week: week)))") {
                                let time = TimeFilter.week(year: year, week: week)
                                filter.time = filter.time == time ? .all : time
                            }
                        }
                    } label: {
                        Text(verbatim: "\(year) 年 · \(weeks.count) 周")
                    }
                }
            }
        } label: {
            rowLabel(
                title: isSelected ? (filter.time.title ?? "周次") : "周次",
                symbol: "calendar.badge.clock",
                count: isSelected ? count(for: filter.time) : nil,
                isSelected: isSelected,
                showsMenuHint: true
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    // MARK: - 时间行

    private func timeButton(_ time: TimeFilter, title: String, symbol: String) -> some View {
        let isSelected = time == .all ? filter.isAllSelected : filter.time == time
        return Button {
            if time == .all {
                // 「全部」等于回到起点，顺手把所有筛选项清掉
                filter = EntryFilter()
            } else {
                filter.time = isSelected ? .all : time
            }
        } label: {
            rowLabel(
                title: title,
                symbol: symbol,
                count: count(for: time),
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    // MARK: - 类型

    private func attachmentRow(_ value: AttachmentFilter) -> some View {
        let isSelected = filter.attachments == value
        return Button {
            filter.attachments = isSelected ? .any : value
            filter.privateOnly = false
            filter.backfilledOnly = false
        } label: {
            rowLabel(
                title: value.title,
                symbol: value.symbol,
                count: count(for: value),
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    private var privateRow: some View {
        let isSelected = filter.privateOnly
        return Button {
            filter.privateOnly.toggle()
            filter.attachments = .any
            filter.backfilledOnly = false
        } label: {
            rowLabel(
                title: "隐私",
                symbol: "lock.fill",
                count: privateCount,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    private var backfilledRow: some View {
        row(title: "补写", symbol: "clock.arrow.circlepath", count: backfilledCount,
            isSelected: filter.backfilledOnly) {
            filter.backfilledOnly.toggle()
            filter.attachments = .any
            filter.privateOnly = false
        }
    }

    // MARK: - 地点

    private var provinceMenu: some View {
        let selected = filter.locationProvince
        let isSelected = selected != nil
        return Menu {
            Button("不限省份") {
                filter.locationProvince = nil
                filter.locationCity = nil
            }
            Divider()
            ForEach(provinceCounts) { item in
                Button {
                    filter.locationProvince = selected == item.name ? nil : item.name
                    filter.locationCity = nil
                } label: {
                    Text(verbatim: "\(item.name) · \(item.count)")
                }
            }
        } label: {
            rowLabel(
                title: selected ?? "省份",
                symbol: "map",
                count: selected.map { count(province: $0) },
                isSelected: isSelected,
                showsMenuHint: true
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    private var cityMenu: some View {
        let selected = filter.locationCity
        let isSelected = selected != nil
        return Menu {
            Button("不限城市") { filter.locationCity = nil }
            Divider()
            ForEach(cityCounts) { item in
                Button {
                    if selected == item.name {
                        filter.locationCity = nil
                    } else {
                        filter.locationCity = item.name
                        filter.locationProvince = province(ofCity: item.name)
                    }
                } label: {
                    Text(verbatim: "\(item.name) · \(item.count)")
                }
            }
        } label: {
            rowLabel(
                title: selected ?? "城市",
                symbol: "building.2",
                count: selected.map { count(city: $0) },
                isSelected: isSelected,
                showsMenuHint: true
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    // MARK: - 行样式

    private func rowLabel(
        title: String,
        symbol: String,
        count: Int?,
        isSelected: Bool,
        tint: Color? = nil,
        showsMenuHint: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Group {
                if symbol == todaySymbol {
                    CalendarDayIcon(symbol: symbol)
                } else {
                    Image(systemName: symbol)
                }
            }
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? (tint ?? accent) : Color.secondary)
                .frame(width: 16)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let count {
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if showsMenuHint {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .fontWeight(isSelected ? .semibold : .regular)
    }

    private func row(
        title: String,
        symbol: String,
        count: Int?,
        isSelected: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            rowLabel(
                title: title,
                symbol: symbol,
                count: count,
                isSelected: isSelected,
                tint: tint
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.14) : Color.clear)
    }

    // MARK: - 统计

    private func entries(excluding facet: EntryFilter.Facet) -> [DiaryEntry] {
        filter.entries(in: entries, excluding: facet)
    }

    private func count(for time: TimeFilter) -> Int {
        entries(excluding: .time).filter { time.matches(dayKey: $0.dayKey) }.count
    }

    private func count(for attachment: AttachmentFilter) -> Int {
        entries(excluding: .type).filter(attachment.matches).count
    }

    private var privateCount: Int {
        entries(excluding: .type).filter(\.isPrivate).count
    }

    private var backfilledCount: Int {
        entries(excluding: .type).filter(\.isBackfilled).count
    }

    /// 只列叠加其它筛选后仍有日记的年份，新的在前。
    private var availableYears: [Int] {
        Set(entries(excluding: .time).compactMap { entry in
            entry.day.map { Calendar.current.component(.year, from: $0) }
        }).sorted(by: >)
    }

    private var availableWeekYears: [Int] {
        Set(entries(excluding: .time).compactMap { entry in
            entry.day.map { TimeFilter.isoCalendar.component(.yearForWeekOfYear, from: $0) }
        }).sorted(by: >)
    }

    private var moodCounts: [Mood: Int] {
        var counts: [Mood: Int] = [:]
        for entry in entries(excluding: .mood) {
            if let mood = entry.mood { counts[mood, default: 0] += 1 }
        }
        return counts
    }

    private struct TagCount: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
    }

    private var provinceCounts: [TagCount] {
        var counts: [String: Int] = [:]
        for entry in entries(excluding: .province) {
            if let province = entry.location?.provinceForFilter, !province.isEmpty {
                counts[province, default: 0] += 1
            }
        }
        return sortedCounts(counts)
    }

    /// 选中省份后，城市列表只留这个省的城市。
    private var cityCounts: [TagCount] {
        var counts: [String: Int] = [:]
        for entry in entries(excluding: .city) {
            guard let city = entry.location?.city, !city.isEmpty else { continue }
            counts[city, default: 0] += 1
        }
        return sortedCounts(counts)
    }

    /// 只列真的有日记的月份，并且不列还没到的月。
    private func monthsWithEntries(in year: Int) -> [Int] {
        TimeFilter.monthsWithEntries(in: year, from: entries(excluding: .time))
            .filter { count(for: .month(year: year, month: $0)) > 0 }
    }

    /// 只列真的有日记的周，并且不列还没到的周。
    private func weeksWithEntries(in year: Int) -> [Int] {
        TimeFilter.weeksWithEntries(in: year, from: entries(excluding: .time))
    }

    private func province(ofCity city: String) -> String? {
        store.visibleEntries
            .first { $0.location?.city == city }?
            .location?.provinceForFilter
    }

    private func count(province: String) -> Int {
        entries(excluding: .province).filter { $0.location?.provinceForFilter == province }.count
    }

    private func count(city: String) -> Int {
        entries(excluding: .city).filter { $0.location?.city == city }.count
    }

    private func showsMenu(_ counts: [TagCount], selected: String?) -> Bool {
        if let selected { return counts.contains { $0.name == selected && $0.count > 0 } }
        return !counts.isEmpty
    }

    private func sortedCounts(_ counts: [String: Int]) -> [TagCount] {
        counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map { TagCount(name: $0.key, count: $0.value) }
    }

    private var weatherCounts: [TagCount] {
        var counts: [String: Int] = [:]
        for entry in entries(excluding: .weather) {
            if let text = entry.weather?.text, !text.isEmpty {
                counts[text, default: 0] += 1
            }
        }
        return sortedCounts(counts)
    }

    private var tagCounts: [TagCount] {
        var counts: [String: Int] = [:]
        for entry in entries(excluding: .tag) {
            for tag in Set(entry.tags) { counts[tag, default: 0] += 1 }
        }
        return sortedCounts(counts)
    }
}

/// 新系统优先使用 SF Symbols，macOS 15 使用相同含义的日期日历。
private struct CalendarDayIcon: View {
    let symbol: String

    var body: some View {
        if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            Image(systemName: symbol)
        } else {
            ZStack {
                CalendarOutline()
                    .stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                Text(symbol.split(separator: ".").first.map(String.init) ?? "")
                    .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .offset(y: 3)
            }
            .frame(width: 14, height: 14)
        }
    }
}

private struct CalendarOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.minX + 1, y: rect.minY + 2,
                                       width: rect.width - 2, height: rect.height - 2.5),
                            cornerSize: CGSize(width: 1.8, height: 1.8))
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 5))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 5))
        for x in [rect.minX + 4, rect.maxX - 4] {
            path.move(to: CGPoint(x: x, y: rect.minY + 0.5))
            path.addLine(to: CGPoint(x: x, y: rect.minY + 3.5))
        }
        return path
    }
}
