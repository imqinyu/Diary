import AppKit
import SwiftUI

struct BrowserView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(BackupManager.self) private var backup
    @Environment(PrivacyManager.self) private var privacy
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    @State private var selection: String?
    @State private var query = ""
    @State private var filter = EntryFilter()
    @State private var isShowingMap = false
    @State private var isInserting = false

    private var visibleEntries: [DiaryEntry] {
        searchEntries.filter(filter.matches)
    }

    private var searchEntries: [DiaryEntry] {
        store.visibleEntries.filter(matchesQuery)
    }

    var body: some View {
        NavigationSplitView {
            FilterSidebar(filter: $filter, entries: searchEntries)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } content: {
            EntryListView(entries: visibleEntries, selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 330)
        } detail: {
            detail
        }
        .searchable(text: $query, placement: .toolbar, prompt: "搜索日记")
        .onSubmit(of: .search) {
            // 搜索框就是解锁入口：输密码回车，静默显示隐藏内容，不留任何提示。
            // 密码不对就当普通搜索词，不弹指纹——否则正常搜索也会被指纹框打断。
            guard privacy.hasPassword, privacy.isLocked else { return }
            let input = query
            Task {
                if await privacy.tryUnlock(input) {
                    query = ""
                    // 刚拿到密钥：重新读一遍把私密正文解出来，顺手把旧的明文条目加密
                    store.reload()
                    store.encryptPlaintextPrivateEntries()
                    if selection == nil {
                        selection = store.visibleEntries.first?.id
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // 打开设置窗口、文件面板时窗口也会失焦，但人还在这台电脑前，不该上锁。
            // 稍等一下再看应用是不是还在前台。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if !NSApp.isActive {
                    privacy.lock()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            privacy.lock()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingMap = true
                } label: {
                    Label("地图", systemImage: "map")
                }
                .help("在地图上查看这些日记")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "album")
                } label: {
                    Label("相册", systemImage: "photo.on.rectangle.angled")
                }
                .help("打开相册")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInserting = true
                } label: {
                    Label("补写", systemImage: "calendar.badge.plus")
                }
                .help("补写以前某一天的日记")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.createTodayEntry()
                } label: {
                    Label("新建", systemImage: "square.and.pencil")
                }
                .help("新建今天的条目 ⌘N")
            }
        }
        .sheet(isPresented: $isInserting) {
            InsertEntrySheet(
                onInsert: { date in
                    isInserting = false
                    store.insertEntry(on: date)
                },
                onCancel: { isInserting = false }
            )
        }
        .onChange(of: privacy.isUnlocked) { _, unlocked in
            // 上锁后立刻撤掉「只看隐私」，避免留下一个空列表惹人起疑
            if !unlocked { filter.privateOnly = false }
        }
        .onChange(of: store.lastCreatedID) { _, newValue in
            guard let newValue else { return }
            selection = newValue
            store.lastCreatedID = nil
            if preferences.autoFillMeta {
                store.pendingAutoFillID = newValue
            }
        }
        .onChange(of: store.lastInsertedID) { _, newValue in
            guard let newValue else { return }
            filter = EntryFilter()
            query = ""
            selection = newValue
            store.lastInsertedID = nil
        }
        .onChange(of: store.focusEntryID) { _, newValue in
            guard let newValue else { return }
            selection = newValue
            store.focusEntryID = nil
        }
        .onChange(of: store.requestedEntryID) { _, newValue in
            guard let newValue else { return }
            filter = EntryFilter()
            query = ""
            selection = newValue
            store.requestedEntryID = nil
        }
        .onAppear {
            if selection == nil {
                selection = visibleEntries.first?.id
            }
        }
        .sheet(isPresented: $isShowingMap) {
            DiaryMapView(entries: visibleEntries)
                .environment(store)
        }
        .sheet(isPresented: setupBinding) {
            BackupSetupView()
                .environment(store)
                .environment(backup)
                .interactiveDismissDisabled()
        }
        .task {
            await backup.autoBackupIfNeeded(store: store)
            // 应用长期开着也要按时备份，不能只在启动时检查一次
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                guard !Task.isCancelled else { break }
                await backup.autoBackupIfNeeded(store: store)
            }
        }
        .onChange(of: backup.isConfigured) { _, isConfigured in
            guard isConfigured else { return }
            Task { await backup.autoBackupIfNeeded(store: store) }
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let entry = store.entry(with: id) {
            EntryDetailView(entry: entry, reloadGeneration: store.externalReloadGeneration)
                .id(entry.id + ":sync:" + String(store.externalReloadGeneration))
        } else {
            ContentUnavailableView(
                "选择一页",
                systemImage: "book",
                description: Text("左边挑日期，中间挑条目。")
            )
        }
    }

    private var setupBinding: Binding<Bool> {
        Binding(
            get: { !backup.isConfigured },
            set: { _ in }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private func matchesQuery(_ entry: DiaryEntry) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystack = [
            entry.title,
            entry.excerpt,
            entry.bodyMarkdown,
            entry.tags.joined(separator: " "),
            entry.location?.name ?? "",
            entry.mood?.displayName ?? ""
        ].joined(separator: "\n")
        return haystack.localizedStandardContains(trimmed)
    }
}
