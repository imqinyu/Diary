import SwiftUI

@main
struct DiaryApp: App {
    @State private var privacy: PrivacyManager
    @State private var store: DiaryStore
    @State private var backup = BackupManager()
    @State private var preferences = AppPreferences()
    @State private var locationService = LocationService()
    @State private var sync = SyncManager()
    @State private var nearby = NearbyManager()

    init() {
        let privacy = PrivacyManager()
        _privacy = State(initialValue: privacy)
        _store = State(initialValue: DiaryStore(privacy: privacy))
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .accentColor(preferences.themeColor.color)
                .tint(preferences.themeColor.color)
                .environment(store)
                .environment(privacy)
                .environment(backup)
                .environment(preferences)
                .environment(locationService)
                .environment(sync)
                .environment(nearby)
                .onAppear { sync.start(store: store) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if sync.automaticSync { Task { await sync.syncNow(store: store) } }
                }
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建条目") {
                    store.createTodayEntry()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Window("相册", id: "album") {
            AlbumView()
                .accentColor(preferences.themeColor.color)
                .tint(preferences.themeColor.color)
                .environment(store)
                .environment(privacy)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 980, height: 720)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .accentColor(preferences.themeColor.color)
                .tint(preferences.themeColor.color)
                .environment(store)
                .environment(privacy)
                .environment(backup)
                .environment(preferences)
                .environment(locationService)
                .environment(sync)
                .environment(nearby)
        }
        .defaultSize(width: 560, height: 600)
        .windowResizability(.automatic)
    }
}
