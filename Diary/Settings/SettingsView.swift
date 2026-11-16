import AppKit
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable {
        case general
        case statistics
        case backup
    }

    @State private var selection: Tab = .general
    @State private var contentHeights: [Tab: CGFloat] = [:]
    @State private var windowResizeController = SettingsWindowResizeController()

    init(initialTab: Tab = .general) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            settingsPage(.general) { GeneralSettingsView() }
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(Tab.general)

            settingsPage(.statistics) { StatisticsView() }
                .tabItem { Label("统计", systemImage: "chart.bar") }
                .tag(Tab.statistics)

            settingsPage(.backup) { BackupSettingsView() }
                .tabItem { Label("备份", systemImage: "externaldrive.badge.timemachine") }
                .tag(Tab.backup)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func settingsPage<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(20)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                // 内容立即按自然高度排版，动画只作用于原生窗口边框。
                .transaction { $0.animation = nil }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeights[tab] = ceil(height)
                }
        }
        .background {
            SettingsWindowSizer(
                contentHeight: tab == selection ? contentHeights[tab] : nil,
                controller: windowResizeController
            )
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppPreferences.self) private var preferences
    @Environment(LocationService.self) private var locationService
    @Environment(PrivacyManager.self) private var privacy

    var body: some View {
        SettingsForm {
            SettingsSection("外观") {
                ThemeColorPicker()
            }

            SettingsSection("记录位置与天气") {
                Toggle("新建时自动填充", isOn: Binding(
                    get: { preferences.autoFillMeta },
                    set: { preferences.autoFillMeta = $0 }
                ))
                Text("打开后，新建一页时会自动记一次当前位置和天气。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("位置详细程度", selection: Binding(
                    get: { preferences.locationDetail },
                    set: { preferences.locationDetail = $0 }
                )) {
                    ForEach(LocationDetail.allCases) { detail in
                        Text(detail.title).tag(detail)
                    }
                }
                Text(verbatim: "示例：\(preferences.locationDetail.example)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("日记存放位置") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(store.dataRoot.path)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }

                HStack {
                    Button("在访达中显示") {
                        store.revealInFinder()
                    }
                    Button("更改…") {
                        chooseFolder()
                    }
                }
            }

            SettingsSection {
                Text("每条日记都是一个纯文本 Markdown 文件，图片放在同名的 .assets 文件夹里。你可以直接用任何编辑器打开、用 Git 管理、或者拷到别的设备上。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 锁着的时候整组设置都不渲染，旁人翻设置也看不出有隐私功能。
            if privacy.canShowSettings {
                PrivacySettingsSection()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "使用这个文件夹"
        panel.message = "选择一个用来存日记的文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.changeRoot(to: url)
    }
}

private struct ThemeColorPicker: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("主题色")
            HStack(alignment: .top, spacing: 8) {
                ForEach(ThemeColor.allCases) { theme in
                    let isSelected = preferences.themeColor == theme
                    Button {
                        preferences.themeColor = theme
                    } label: {
                        VStack(spacing: 8) {
                            Group {
                                if let color = theme.color {
                                    Circle().fill(color)
                                } else {
                                    Circle().fill(AngularGradient(
                                        colors: [.blue, .purple, .pink, .orange, .green, .teal, .blue],
                                        center: .center
                                    ))
                                }
                            }
                            .frame(width: 28, height: 28)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(4)
                            .overlay {
                                Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                            }
                            Text(theme.title)
                                .font(.caption)
                                .foregroundStyle(isSelected ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(theme.title)
                    .accessibilityLabel(theme.title)
                    .accessibilityValue(isSelected ? "已选择" : "未选择")
                }
            }
            Text("应用于选中状态、按钮和统计图表，选择后立即生效。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 备份

private struct BackupSettingsView: View {
    @Environment(BackupManager.self) private var backup
    @Environment(DiaryStore.self) private var store

    @State private var archives: [URL] = []
    @State private var pendingRestore: URL?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    var body: some View {
        SettingsForm {
            SettingsSection("备份位置") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(backup.folderURL?.path ?? "尚未选择")
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("更改…") { chooseFolder() }
                }

                HStack(spacing: 10) {
                    Button("立即备份") {
                        Task {
                            await backup.backupNow(store: store)
                            refresh()
                        }
                    }
                    .disabled(backup.isBusy)

                    Button("导出…") { exportArchive() }
                        .disabled(backup.isBusy)

                    Button("在访达中显示") {
                        if let folder = backup.folderURL {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }

                    if backup.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }

                Text(backup.lastBackupDate.map { "上次备份：\(Self.dateFormatter.string(from: $0))" } ?? "还没有备份过")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("自动备份") {
                Picker("频率", selection: Binding(
                    get: { backup.intervalDays },
                    set: { backup.intervalDays = $0 }
                )) {
                    ForEach(1...7, id: \.self) { day in
                        Text("每 \(day) 天").tag(day)
                    }
                }
                Text("启动时会检查一次，运行期间每几小时再查一次；最多保留最近 \(BackupManager.maxBackups) 个自动备份。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("从备份恢复") {
                if archives.isEmpty {
                    Text("这里还没有备份文件")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(archives, id: \.self) { archive in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.zipper")
                                .foregroundStyle(.secondary)
                            Text(archive.lastPathComponent)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("恢复") { pendingRestore = archive }
                                .disabled(backup.isBusy)
                        }
                    }
                }
                if let message = backup.infoMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { refresh() }
        .confirmationDialog("用这个备份替换当前所有日记？", isPresented: restoreBinding) {
            Button("恢复", role: .destructive) {
                guard let archive = pendingRestore else { return }
                Task {
                    await backup.restore(from: archive, store: store)
                    refresh()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("替换前会先自动备份一次当前状态。")
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好", role: .cancel) { backup.errorMessage = nil }
        } message: {
            Text(backup.errorMessage ?? "")
        }
    }

    private var restoreBinding: Binding<Bool> {
        Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { backup.errorMessage != nil },
            set: { if !$0 { backup.errorMessage = nil } }
        )
    }

    private func refresh() {
        archives = Array(backup.backups().prefix(BackupManager.maxBackups))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "用这个文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try backup.setFolder(url, dataRoot: store.dataRoot)
            refresh()
        } catch {
            backup.errorMessage = error.localizedDescription
        }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Diary-\(BackupManager.stamp()).zip"
        panel.message = "导出一份完整的日记压缩包"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await backup.export(to: url, store: store)
        }
    }
}

// MARK: - 隐私

private struct PrivacySettingsSection: View {
    @Environment(PrivacyManager.self) private var privacy
    @Environment(DiaryStore.self) private var store

    @State private var setupPassword = ""
    @State private var setupConfirm = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var newConfirm = ""
    @State private var disablePassword = ""
    @State private var message: String?
    @State private var isShowingAudit = false

    var body: some View {
        SettingsSection("隐私保护") {
            if privacy.hasPassword {
                statusRow

                if BiometricAuthenticator.isAvailable {
                    Toggle("解锁时额外要求\(BiometricAuthenticator.biometryName)", isOn: Binding(
                        get: { privacy.useBiometrics },
                        set: { privacy.useBiometrics = $0 }
                    ))
                    Text("密码正确后还会再要一次\(BiometricAuthenticator.biometryName)，两个都通过才解锁。密码不小心被别人知道了也还有一道。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                auditRow

                DisclosureGroup("修改密码") {
                    SecureField("当前密码", text: $currentPassword)
                    SecureField("新密码", text: $newPassword)
                    SecureField("再输一次", text: $newConfirm)
                    HStack(spacing: 10) {
                        Button("修改密码") { changePassword() }
                        messageText
                    }
                }

                DisclosureGroup("关闭隐私保护") {
                    Text("关闭后所有条目都会重新显示，但文件里的私密标记会保留；以后重新设置密码，它们又会被藏起来。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("输入当前密码", text: $disablePassword)
                    Button("关闭隐私保护", role: .destructive) { disablePrivacy() }
                }

                DisclosureGroup("隐私是怎么工作的") {
                    Label("在编辑页底部点小锁，把这一天的内容标记为隐私条目。", systemImage: "lock")
                    Label("锁定后，这些条目在列表、筛选、相册里全都不会出现。", systemImage: "eye.slash")
                    Label("解锁：在搜索框直接输入密码并回车，内容会静默出现。", systemImage: "magnifyingglass")
                    Label("切到别的应用时自动重新上锁。", systemImage: "rectangle.on.rectangle.slash")
                    Text("当前版本只做界面隐藏：私密条目的正文在磁盘上仍是明文 Markdown，用文本编辑器仍能直接看到。真正的加密留到以后。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            } else {
                Text("设置一个密码后，被标记为隐私的条目只有在解锁后才可见。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("密码（至少 4 位）", text: $setupPassword)
                SecureField("再输一次", text: $setupConfirm)
                HStack(spacing: 10) {
                    Button("设置密码") { createPassword() }
                    messageText
                }
            }
        }
        .sheet(isPresented: $isShowingAudit) {
            PrivacyAuditView()
                .environment(privacy)
        }
    }

    private var statusRow: some View {
        HStack {
            Label(
                privacy.isUnlocked ? "已解锁" : "已锁定",
                systemImage: privacy.isUnlocked ? "lock.open" : "lock.fill"
            )
            Spacer()
            Button("立即上锁") { privacy.lock() }
                .disabled(!privacy.isUnlocked)
        }
    }

    private var auditRow: some View {
        Button {
            isShowingAudit = true
        } label: {
            HStack(spacing: 8) {
                Label("访问记录", systemImage: "list.bullet.rectangle")
                Spacer(minLength: 8)
                Text(verbatim: "\(privacy.auditLog.entries.count) 条")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var messageText: some View {
        if let message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func createPassword() {
        guard setupPassword == setupConfirm else {
            message = "两次输入不一致"
            return
        }
        if privacy.setPassword(setupPassword) {
            setupPassword = ""
            setupConfirm = ""
            message = "已设置"
        } else {
            message = privacy.errorMessage
        }
    }

    private func changePassword() {
        guard newPassword == newConfirm else {
            message = "两次输入不一致"
            return
        }
        if privacy.changePassword(current: currentPassword, new: newPassword) {
            // 密钥换了，私密条目要整体重加密一遍
            store.reencryptPrivateEntries()
            currentPassword = ""
            newPassword = ""
            newConfirm = ""
            message = "已修改"
        } else {
            message = privacy.errorMessage
        }
    }

    private func disablePrivacy() {
        // 先用当前密钥把内容解回明文，否则密码一删内容就永远打不开了
        if privacy.verify(disablePassword) {
            store.decryptPrivateEntries()
        }
        if privacy.removePassword(current: disablePassword) {
            disablePassword = ""
            message = "已关闭"
        } else {
            message = privacy.errorMessage
        }
    }
}

// MARK: - 访问记录

struct PrivacyAuditView: View {
    @Environment(PrivacyManager.self) private var privacy
    @Environment(\.dismiss) private var dismiss

    /// nil = 全部
    @State private var range: Int?

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var entries: [PrivacyAuditEntry] {
        privacy.auditLog.recent(days: range)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("访问记录")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Picker("范围", selection: $range) {
                Text("最近一周").tag(Int?.some(7))
                Text("最近一月").tag(Int?.some(30))
                Text("全部").tag(Int?.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if entries.isEmpty {
                VStack {
                    Spacer()
                    Text("这段时间没有记录")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(entries) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(item.success ? Color.green : Color.red)
                            .font(.caption)
                        Text(item.method)
                            .font(.callout)
                        Spacer(minLength: 8)
                        Text(timeText(item.date))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("只记时间与方式，不记密码；记录不会被清除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "共 \(entries.count) 条")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 520, height: 480)
    }

    private func timeText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dayFormatter.string(from: date)
    }
}
