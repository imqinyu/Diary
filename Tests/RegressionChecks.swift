import Foundation

@main
struct RegressionChecks {
    @MainActor
    static func main() {
        let today = DayKey.today()
        let yesterday = DayKey.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        let entries = [
            entry("happy-photo", day: today, mood: .happy, images: 1, tag: "旅行", province: "浙江省", city: "杭州市", weather: "晴"),
            entry("happy-text", day: today, mood: .happy, images: 0, tag: "生活", province: "浙江省", city: "宁波市", weather: "雨"),
            entry("happy-old", day: "2020-01-02", mood: .happy, images: 2, tag: "旅行", province: "江苏省", city: "南京市", weather: "晴"),
            entry("calm-photo", day: today, mood: .calm, images: 1, tag: "生活", province: "上海市", city: "上海市", weather: "晴"),
            entry("calm-text", day: yesterday, mood: .calm, images: 0, tag: "旅行", province: "浙江省", city: "杭州市", weather: "阴")
        ]

        var filter = EntryFilter()
        precondition(filter.isAllSelected)
        let activeFilters = [
            EntryFilter(time: .today), EntryFilter(mood: .happy), EntryFilter(tag: "旅行"),
            EntryFilter(attachments: .withImages), EntryFilter(locationProvince: "浙江省"),
            EntryFilter(locationCity: "杭州市"), EntryFilter(weatherText: "晴"), EntryFilter(privateOnly: true)
        ]
        precondition(activeFilters.allSatisfy { !$0.isAllSelected })

        filter.mood = .happy
        expect(entries.filter(filter.matches), ["happy-photo", "happy-text", "happy-old"])
        let types = filter.entries(in: entries, excluding: .type)
        precondition(types.filter(AttachmentFilter.withImages.matches).count == 2)
        precondition(types.filter(AttachmentFilter.withoutImages.matches).count == 1)
        precondition(filter.entries(in: entries, excluding: .time).filter { TimeFilter.today.matches(dayKey: $0.dayKey) }.count == 2)
        precondition(filter.entries(in: entries, excluding: .tag).filter { $0.tags.contains("旅行") }.count == 2)
        precondition(filter.entries(in: entries, excluding: .province).filter { $0.location?.provinceForFilter == "浙江省" }.count == 2)
        precondition(filter.entries(in: entries, excluding: .weather).filter { $0.weather?.text == "雨" }.count == 1)

        filter.time = .today
        filter.attachments = .withImages
        expect(entries.filter(filter.matches), ["happy-photo"])
        expect(filter.entries(in: entries, excluding: .time), ["happy-photo", "happy-old"])
        expect(filter.entries(in: entries, excluding: .mood), ["happy-photo", "calm-photo"])
        expect(filter.entries(in: entries, excluding: .type), ["happy-photo", "happy-text"])

        // 搜索结果是候选集合，计数也必须在该集合中计算。
        let searchResults = entries.filter { $0.id == "happy-photo" || $0.id == "calm-photo" }
        expect(filter.entries(in: searchResults, excluding: .type), ["happy-photo"])

        filter.locationProvince = "浙江省"
        filter.locationCity = "杭州市"
        expect(filter.entries(in: entries, excluding: .province), ["happy-photo"])
        filter.attachments = .any
        expect(filter.entries(in: entries, excluding: .city), ["happy-photo", "happy-text"])
        precondition(filter.excluding(.province).locationCity == nil)

        // 无结果时保留原选择；移除该条件能恢复其它候选。
        filter.tag = "不存在"
        precondition(entries.filter(filter.matches).isEmpty)
        precondition(filter.entries(in: entries, excluding: .type).isEmpty)
        expect(filter.entries(in: entries, excluding: .tag), ["happy-photo"])
        precondition(filter.tag == "不存在")
        precondition(filter.entries(in: [], excluding: .mood).isEmpty)

        filter = EntryFilter(mood: .happy)
        var updated = entries
        updated[1].attachmentCount = 1
        precondition(filter.entries(in: updated, excluding: .type).filter(AttachmentFilter.withImages.matches).count == 3)

        // 类型候选替换「隐私」和图片条件；其它维度仍然保留它们。
        var privateEntry = entries[0]
        privateEntry.id = "private"
        privateEntry.isPrivate = true
        let unlocked = entries + [privateEntry]
        filter.privateOnly = true
        expect(unlocked.filter(filter.matches), ["private"])
        precondition(filter.entries(in: unlocked, excluding: .type).count == 4)
        expect(filter.entries(in: unlocked, excluding: .mood), ["private"])
        let locked = unlocked.filter { !$0.isPrivate }
        precondition(filter.entries(in: locked, excluding: .mood).isEmpty)
        precondition(filter.entries(in: locked, excluding: .type).allSatisfy { !$0.isPrivate })

        let suite = "DiaryRegressionChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        precondition(preferences.themeColor == .system)
        preferences.autoFillMeta = true
        preferences.locationDetail = .city
        for theme in ThemeColor.allCases {
            preferences.themeColor = theme
            let reloaded = AppPreferences(defaults: defaults)
            precondition(reloaded.themeColor == theme)
            precondition(reloaded.autoFillMeta && reloaded.locationDetail == .city)
        }
        defaults.set("obsolete-theme", forKey: "AppThemeColor")
        precondition(AppPreferences(defaults: defaults).themeColor == .system)

        let frame = NSRect(x: 120, y: 300, width: 560, height: 500)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        let shrink = SettingsWindowGeometry.targetFrame(current: frame, viewportHeight: 450, contentHeight: 260, screen: screen)
        precondition(shrink.height == 310 && shrink.maxY == frame.maxY && shrink.width == frame.width)
        let grow = SettingsWindowGeometry.targetFrame(current: frame, viewportHeight: 450, contentHeight: 650, screen: screen)
        precondition(grow.height == 700 && grow.maxY == frame.maxY)
        let overflow = SettingsWindowGeometry.targetFrame(current: frame, viewportHeight: 450, contentHeight: 2000, screen: screen)
        precondition(overflow.height == 976 && overflow.minY >= screen.minY && overflow.maxY <= screen.maxY)
        print("PASS: selection, combined counts, search, zero results, live metadata, privacy visibility, theme persistence, and settings resize geometry")
    }

    static func expect(_ entries: [DiaryEntry], _ ids: Set<String>) {
        precondition(Set(entries.map(\.id)) == ids, "Unexpected entries: \(entries.map(\.id))")
    }

    static func entry(_ id: String, day: String, mood: Mood, images: Int, tag: String, province: String, city: String, weather: String) -> DiaryEntry {
        DiaryEntry(
            id: id, dayKey: day, sequence: 1, created: Date(), updated: Date(), title: id,
            mood: mood, tags: [tag], isPrivate: false, isDeleted: false, deletedAt: nil,
            wordCount: 10, attachmentCount: images,
            location: EntryLocation(name: "\(province) \(city)", province: province, city: city),
            weather: EntryWeather(text: weather), excerpt: "", fileURL: URL(fileURLWithPath: "/tmp/\(id).md"), bodyMarkdown: ""
        )
    }
}
