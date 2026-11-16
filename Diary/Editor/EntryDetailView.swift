import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EntryDetailView: View {
    let entry: DiaryEntry

    @Environment(DiaryStore.self) private var store
    @Environment(PrivacyManager.self) private var privacy
    @Environment(AppPreferences.self) private var preferences
    @Environment(LocationService.self) private var locationService

    @State private var controller = RichTextController()
    @State private var latestMarkdown: String
    @State private var titleDraft: String
    @State private var saveTask: Task<Void, Never>?
    @State private var isImportingImage = false
    @State private var isConfirmingDelete = false
    @State private var isManualMeta = false
    @State private var metaError: String?
    /// 插入的旧日记到点自动变只读，定时刷新一下界面状态。
    @State private var now = Date()

    private let initialAttributedText: NSAttributedString
    private let reloadGeneration: Int

    init(entry: DiaryEntry, reloadGeneration: Int = 0) {
        self.entry = entry
        self.reloadGeneration = reloadGeneration
        _latestMarkdown = State(initialValue: entry.bodyMarkdown)
        _titleDraft = State(initialValue: entry.title)
        initialAttributedText = MarkdownCodec.decode(
            entry.bodyMarkdown,
            entryDirectory: entry.fileURL.deletingLastPathComponent()
        )
    }

    private var current: DiaryEntry {
        store.entry(with: entry.id) ?? entry
    }

    private var writable: Bool {
        current.canEdit(at: now)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !current.isContentAvailable {
                ContentUnavailableView("正文已加密", systemImage: "lock.doc",
                    description: Text("在设置中设置这篇日记使用的隐私密码，再通过搜索框解锁。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            RichTextEditor(
                initialText: initialAttributedText,
                isEditable: writable,
                controller: controller,
                footerText: footerText,
                onPasteImage: { image in
                    guard let path = store.importImage(image, for: entry.id) else { return nil }
                    return MarkdownCodec.makeAttachment(image: image, path: path)
                },
                onChange: handleChange
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if writable {
                formatBar
            }
        }
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            insertImage(from: result)
        }
        .confirmationDialog("删除这一页？", isPresented: $isConfirmingDelete) {
            Button("删除", role: .destructive) {
                performDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            if store.willLeaveTombstone(entryID: entry.id) {
                Text("这是已经封存的旧日记：正文会被清空，但这一页的痕迹（日期、心情、地点、字数、预览）会永久保留。")
            } else {
                Text("这一页还没封存，会被完全删除，不留任何记录。")
            }
        }
        .sheet(isPresented: $isManualMeta) {
            ManualMetaSheet(entry: current) { location, weather in
                store.updateMeta(entryID: entry.id, location: location, weather: weather)
                isManualMeta = false
            } onCancel: {
                isManualMeta = false
            }
        }
        .alert("没能记录位置", isPresented: metaErrorBinding) {
            Button("手动填写") {
                metaError = nil
                isManualMeta = true
            }
            Button("好", role: .cancel) { metaError = nil }
        } message: {
            Text(metaError ?? "")
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
        .task {
            consumeAutoFill()
        }
        .onChange(of: store.pendingAutoFillID) { _, _ in
            consumeAutoFill()
        }
        .onDisappear {
            flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: DiaryStore.flushEditorsNotification)) { notification in
            guard notification.object as? DiaryStore === store else { return }
            flush()
        }
    }

    /// 设置里开了自动填充时，新建的那一页自己安静地记录一次，不弹确认框。
    private func consumeAutoFill() {
        guard store.pendingAutoFillID == entry.id else { return }
        store.pendingAutoFillID = nil
        guard writable else { return }
        recordMeta(silently: true)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if writable {
                    TextField("", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold))
                        .overlay(alignment: .leading) {
                            // 没起标题时把日期当标题显示，但不要显示成灰色的 placeholder
                            if titleDraft.isEmpty {
                                Text(autoTitle)
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onSubmit { commitTitle() }
                        .onChange(of: titleDraft) { _, _ in commitTitle() }
                } else {
                    Text(titleText)
                        .font(.system(size: 22, weight: .bold))
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                if current.isPrivate, privacy.isUnlocked {
                    Label("隐私", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 用自动换行排版：窗口一窄也不会把「2026年11月15日 星期日」掰成两行
            FlowLayout(spacing: 12, lineSpacing: 6) {
                Label(
                    "\(DayKey.display(current.dayKey)) \(DayKey.weekday(current.dayKey))",
                    systemImage: "calendar"
                )
                .fixedSize()

                if current.isBackfilled {
                    Label("补写", systemImage: "clock.arrow.circlepath")
                        .fixedSize()
                }

                if let mood = current.mood {
                    Label(mood.displayName, systemImage: mood.symbolName)
                        .foregroundStyle(mood.tint)
                        .fixedSize()
                }
                Label(wordCountText, systemImage: "text.alignleft")
                    .fixedSize()
                if let location = current.location {
                    Label(location.name, systemImage: "location")
                        .fixedSize()
                }
                if let weather = current.weather {
                    Label(weatherText(weather), systemImage: weather.symbol)
                        .fixedSize()
                }
                Text(verbatim: "创建于 " + Self.timeFormatter.string(from: current.created))
                    .monospacedDigit()
                    .fixedSize()
                if let until = current.editableUntil, writable {
                    Label(
                        "补写至 " + Self.timeFormatter.string(from: until),
                        systemImage: "clock"
                    )
                    .fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            if writable || !current.tags.isEmpty {
                TagRow(entry: current, isEditable: writable)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var wordCountText: String {
        "\(current.wordCount) 字"
    }

    /// 最后编辑时间作为正文的最后一页，跟着文本一起滚动。
    private var footerText: String {
        "最后编辑于 " + Self.fullTimeFormatter.string(from: current.updated)
    }

    private func weatherText(_ weather: EntryWeather) -> String {
        if let temperature = weather.temperature {
            return "\(weather.text) \(Int(temperature.rounded()))°"
        }
        return weather.text
    }

    // MARK: - 底部格式栏

    private var formatBar: some View {
        HStack(spacing: 14) {
            Button {
                let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.needsDeletionConfirmation(markdown: latestMarkdown, title: title == autoTitle ? "" : title) {
                    isConfirmingDelete = true
                } else {
                    performDelete()
                }
            } label: {
                Image(systemName: "trash")
            }
            .help(store.willLeaveTombstone(entryID: entry.id)
                  ? "删除（正文清空，记录保留）"
                  : "删除（完全移除，不留记录）")

            Divider().frame(height: 16)

            Menu {
                Button("不记录心情") {
                    store.updateMood(entryID: entry.id, mood: nil)
                }
                Divider()
                ForEach(Mood.allCases) { mood in
                    Button {
                        store.updateMood(entryID: entry.id, mood: mood)
                    } label: {
                        Label(mood.displayName, systemImage: mood.symbolName)
                    }
                }
            } label: {
                Image(systemName: current.mood?.symbolName ?? "face.smiling")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 22)
            .help("心情")

            Button {
                isImportingImage = true
            } label: {
                Image(systemName: "photo.on.rectangle")
            }
            .help("插入图片")

            Menu {
                Button {
                    recordMeta()
                } label: {
                    Label("记录位置与天气", systemImage: "location.circle")
                }
                Button {
                    isManualMeta = true
                } label: {
                    Label("手动填写…", systemImage: "square.and.pencil")
                }
                if current.location != nil || current.weather != nil {
                    Divider()
                    Button("清除位置与天气", role: .destructive) {
                        store.updateMeta(entryID: entry.id, location: nil, weather: nil)
                    }
                }
            } label: {
                Image(systemName: metaButtonSymbol)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 22)
            .help("位置与天气")

            // 只有解锁时才有这把锁：没设密码、或已上锁时都不显示，
            // 免得旁人看到编辑器里有个锁，猜到有隐藏内容。
            if privacy.isUnlocked {
                Button {
                    store.updatePrivacy(entryID: entry.id, isPrivate: !current.isPrivate)
                } label: {
                    Image(systemName: current.isPrivate ? "lock.fill" : "lock.open")
                }
                .help(current.isPrivate ? "取消隐私标记" : "标记为隐私条目")
            }

            Divider().frame(height: 16)

            Button { controller.toggleBold() } label: { Image(systemName: "bold") }
                .help("加粗 ⌘B")
            Button { controller.toggleItalic() } label: { Image(systemName: "italic") }
                .help("斜体 ⌘I")
            Button { controller.toggleUnderline() } label: { Image(systemName: "underline") }
                .help("下划线 ⌘U")
            Button { controller.toggleStrikethrough() } label: { Image(systemName: "strikethrough") }
                .help("删除线")

            Spacer(minLength: 0)

            Text(wordCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .buttonStyle(.borderless)
        // 工具栏图标用次要色，别被主题色染成一片红/紫——那是 HIG 里的做法，
        // 编辑区里只该有文字和一个安静的工具栏。
        .foregroundStyle(.secondary)
        .tint(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 标题

    private var autoTitle: String {
        let day = DayKey.display(entry.dayKey)
        return store.entries(forDay: entry.dayKey).count > 1 ? "\(day)#\(entry.sequence)" : day
    }

    /// 标题等于默认标题时，文件里保持空标题，避免以后条目数变了标题对不上。
    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed == autoTitle ? "" : trimmed
        guard value != current.title else { return }
        store.updateTitle(entryID: entry.id, title: value)
    }

    private var titleText: String {
        let custom = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = custom.isEmpty ? autoTitle : custom
        return current.isDeleted ? base + "（已删除）" : base
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let fullTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    // MARK: - 保存

    private func performDelete() {
        if store.willLeaveTombstone(entryID: entry.id) {
            flush()
        } else {
            saveTask?.cancel()
            saveTask = nil
        }
        store.deleteEntry(entryID: entry.id)
    }

    private func handleChange(_ attributed: NSAttributedString) {
        let markdown = MarkdownCodec.encode(attributed)
        latestMarkdown = markdown

        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard store.externalReloadGeneration == reloadGeneration else { return }
            store.saveBody(entryID: entry.id, markdown: markdown)
        }
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard store.externalReloadGeneration == reloadGeneration else { return }
        store.saveBody(entryID: entry.id, markdown: latestMarkdown)
    }

    // MARK: - 位置与天气

    private var metaButtonSymbol: String {
        if let weather = current.weather { return weather.symbol }
        if current.location != nil { return "location.fill" }
        return "cloud.sun"
    }

    private var metaErrorBinding: Binding<Bool> {
        Binding(
            get: { metaError != nil },
            set: { if !$0 { metaError = nil } }
        )
    }

    /// 用户点了「记录」之后才真的去定位、查天气。
    /// silently 用于自动填充：拿不到位置就安静跳过，不打断写日记。
    private func recordMeta(silently: Bool = false) {
        metaError = nil
        Task {
            do {
                let location = try await locationService.currentLocation()
                let components = await ReverseGeocoder().placeComponents(for: location)
                let name = components?.name(for: preferences.locationDetail) ?? ""
                let resolved = EntryLocation(
                    name: name.isEmpty ? "未知位置" : name,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    level: preferences.locationDetail.rawValue,
                    province: components?.province,
                    city: components?.city
                )

                var resolvedWeather: EntryWeather?
                if let snapshot = try? await WeatherService().current(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                ) {
                    resolvedWeather = EntryWeather(
                        text: snapshot.text,
                        temperature: snapshot.temperature,
                        code: snapshot.code
                    )
                }

                store.updateMeta(entryID: entry.id, location: resolved, weather: resolvedWeather)
            } catch {
                if !silently {
                    metaError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 图片

    private func insertImage(from result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let relativePath = store.importImage(from: url, for: entry.id) else { return }
        let absolute = store.assetURL(relativePath: relativePath, for: entry)
        guard let image = NSImage(contentsOf: absolute) else { return }
        controller.insertImage(image, relativePath: relativePath)
    }
}
// MARK: - 手动填写位置与天气

private struct ManualMetaSheet: View {
    let onSave: (EntryLocation?, EntryWeather?) -> Void
    let onCancel: () -> Void
    /// 地点没改就原样保留，别把自动记录下来的经纬度洗掉。
    private let originalLocation: EntryLocation?

    @State private var locationName: String
    @State private var selectedWeather: WeatherKind?
    @State private var temperature: String

    init(
        entry: DiaryEntry,
        onSave: @escaping (EntryLocation?, EntryWeather?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        self.originalLocation = entry.location
        _locationName = State(initialValue: entry.location?.name ?? "")
        let kind: WeatherKind
        if let code = entry.weather?.code {
            kind = WeatherKind.from(wmoCode: code)
        } else {
            kind = WeatherKind.from(text: entry.weather?.text)
        }
        _selectedWeather = State(initialValue: kind == .unknown ? nil : kind)
        _temperature = State(initialValue: entry.weather?.temperature.map { String(Int($0.rounded())) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("手动填写位置与天气")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("地点")
                        .foregroundStyle(.secondary)
                    TextField("例如 上海市 徐汇区", text: $locationName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("天气")
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("不记录天气") { selectedWeather = nil }
                        Divider()
                        ForEach(WeatherKind.selectable) { kind in
                            Button {
                                selectedWeather = kind
                            } label: {
                                Label(kind.displayName, systemImage: kind.symbol)
                            }
                        }
                    } label: {
                        HStack {
                            Label(
                                selectedWeather?.displayName ?? "不记录天气",
                                systemImage: selectedWeather?.symbol ?? "cloud"
                            )
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                GridRow {
                    Text("温度")
                        .foregroundStyle(.secondary)
                    TextField("例如 21", text: $temperature)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("地点留空表示不记录位置；温度可以留空。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        let name = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tempText = temperature.trimmingCharacters(in: .whitespacesAndNewlines)

        let location: EntryLocation?
        if name.isEmpty {
            location = nil
        } else if name == originalLocation?.name {
            location = originalLocation
        } else {
            let derived = EntryLocation.deriveComponents(from: name)
            location = EntryLocation(
                name: name,
                latitude: nil,
                longitude: nil,
                level: "manual",
                province: derived.province,
                city: derived.city
            )
        }
        let weatherValue = selectedWeather.map {
            EntryWeather(
                text: $0.displayName,
                temperature: Double(tempText),
                code: $0.wmoCode
            )
        }
        onSave(location, weatherValue)
    }
}
