import AppKit
import SwiftUI

/// 离屏渲染真实设置视图，不读取或操作用户当前窗口。
@main
struct LayoutChecks {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let dataRoot = output.appendingPathComponent("layout-data-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let backupRoot = output.appendingPathComponent("layout-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain([
            "DiaryDataRootPath": dataRoot.path,
            "BackupFolderPath": backupRoot.path
        ], forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }

        let suite = "DiaryLayoutChecks.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suite)!
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyManager(defaults: isolatedDefaults, auditLog: PrivacyAuditLog(fileURL: output.appendingPathComponent("audit.json")))
        let store = DiaryStore(privacy: privacy)
        let preferences = AppPreferences(defaults: isolatedDefaults)
        preferences.themeColor = .purple
        let backup = BackupManager()
        let location = LocationService()
        let sync = SyncManager(defaults: isolatedDefaults, directory: output.appendingPathComponent("sync"), loadCredentials: false)

        var heights: [SettingsView.Tab: CGFloat] = [:]
        for (tab, name) in [(SettingsView.Tab.general, "general"), (.statistics, "statistics"), (.backup, "backup"), (.sync, "sync")] {
            let root = SettingsView(initialTab: tab)
                .environment(store)
                .environment(privacy)
                .environment(preferences)
                .environment(backup)
                .environment(location)
                .environment(sync)
                .accentColor(preferences.themeColor.color)
                .tint(preferences.themeColor.color)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            for _ in 0..<12 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            let size = window.contentLayoutRect.size
            precondition(abs(size.width - 560) < 1)
            precondition(size.height > 100 && size.height < (NSScreen.main?.visibleFrame.height ?? 1000))
            heights[tab] = size.height
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(name).png"))
            }
            print("\(name): \(Int(size.width)) × \(Int(size.height))")
            if tab == .general {
                let tabs = findTabView(in: hosting)!
                precondition(tabs.tabViewItems.count == 4)
                let top = window.frame.maxY
                tabs.selectTabViewItem(at: 2)
                settle(hosting)
                let backupHeight = window.frame.height
                precondition(backupHeight < size.height)
                precondition(abs(window.frame.maxY - top) < 1)
                tabs.selectTabViewItem(at: 0)
                settle(hosting)
                precondition(abs(window.contentLayoutRect.height - size.height) < 1)
                precondition(abs(window.frame.maxY - top) < 1)
                print("PASS: native tabs resize on first selection and when returning to a cached page")
            }
            window.contentView = nil
        }
        precondition(heights[.general] != heights[.backup], "Settings pages should follow their content heights")

        // 用真实侧栏验证主题色、选中状态和联动后的计数布局。
        for (index, mood, image) in [(1, "happy", true), (2, "happy", false), (3, "calm", false)] {
            var document = EntryDocument.decode("""
            ---
            id: layout-\(index)
            date: \(DayKey.today())
            title: 布局检查 \(index)
            mood: \(mood)
            tags: [测试]
            ---
            布局检查。\(image ? "\n![测试](sample.png)" : "")
            """)
            if index == 1 { document.frontMatter.set("backfilled", .scalar("true")) }
            try document.write(to: store.entriesDirectory.appendingPathComponent("layout-\(index).md"))
        }
        store.reload()
        let sidebarCases: [(String, EntryFilter)] = [
            ("sidebar", EntryFilter(mood: .happy)),
            ("sidebar-backfilled", EntryFilter(backfilledOnly: true)),
            ("sidebar-no-photos", EntryFilter(mood: .calm)),
            ("sidebar-zero-mood", EntryFilter(mood: .happy, attachments: .withImages)),
            ("sidebar-no-results", EntryFilter(mood: .happy, tag: "不存在"))
        ]
        for (name, filter) in sidebarCases {
            let sidebar = FilterSidebar(filter: .constant(filter), entries: store.visibleEntries)
                .environment(store)
                .environment(privacy)
                .environment(preferences)
                .accentColor(preferences.themeColor.color)
                .tint(preferences.themeColor.color)
                .frame(width: 210, height: 560)
            let hosting = NSHostingView(rootView: sidebar)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 210, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            settle(hosting)
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(name).png"))
            }
            window.contentView = nil
        }
        let marked = store.entry(with: "layout-1")!
        let row = EntryRow(entry: marked).environment(store).environment(privacy)
            .padding().frame(width: 330, height: 140)
            .background(Color(nsColor: .windowBackgroundColor))
        let rowHosting = NSHostingView(rootView: row)
        let rowWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 140), styleMask: .borderless, backing: .buffered, defer: false)
        rowWindow.contentView = rowHosting
        settle(rowHosting)
        if let bitmap = rowHosting.bitmapImageRepForCachingDisplay(in: rowHosting.bounds) {
            rowHosting.cacheDisplay(in: rowHosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("backfilled-row.png"))
        }
        rowWindow.contentView = nil
        // 记录 AppKit 动画参数，窗口始终离屏；首次定尺寸不动画，后续伸缩动画。
        let animationWindow = ResizeRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        let controller = SettingsWindowResizeController()
        controller.resize(window: animationWindow, to: NSRect(x: 0, y: 100, width: 560, height: 400))
        controller.resize(window: animationWindow, to: NSRect(x: 0, y: 0, width: 560, height: 500))
        controller.resize(window: animationWindow, to: NSRect(x: 0, y: 100, width: 560, height: 400))
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        precondition(animationWindow.animationRequests == [false, shouldAnimate, shouldAnimate])
        print("PASS: initial sizing, native resize animation, and reduced motion preference")
        print("PASS: intrinsic settings heights and screen limits")
    }

    @MainActor
    private static func settle(_ view: NSView) {
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    @MainActor
    private static func findTabView(in view: NSView) -> NSTabView? {
        if let tabs = view as? NSTabView { return tabs }
        for child in view.subviews {
            if let tabs = findTabView(in: child) { return tabs }
        }
        return nil
    }
}

private final class ResizeRecordingWindow: NSWindow {
    var animationRequests: [Bool] = []
    override var isVisible: Bool { true }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        animationRequests.append(animateFlag)
        super.setFrame(frameRect, display: flag, animate: false)
    }
}
