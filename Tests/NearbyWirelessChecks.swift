import SwiftUI
import Foundation
import CoreWLAN
import CoreLocation

@main
struct NearbyWirelessChecks: App {
    @State private var manager = NearbyManager()
    @State private var store: DiaryStore
    private let root: URL
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nearby-wireless-mac-\(UUID().uuidString)")
        self.root = root
        UserDefaults.standard.setVolatileDomain(["DiaryDataRootPath": root.path], forName: UserDefaults.argumentDomain)
        let privacy = PrivacyManager(defaults: UserDefaults(suiteName: "NearbyWirelessChecks")!)
        let store = DiaryStore(privacy: privacy)
        let b = root.appendingPathComponent("entries/2026/11/17/2026-11-17-2.md")
        try! FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! wirelessDoc(2, "Wireless Mac B").write(to: b)
        store.reload()
        _store = State(initialValue: store)
    }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("附近同步真机检查").font(.title2)
                Text("使用临时测试日记，完成后删除测试目录。")
                Text(manager.status).textSelection(.enabled)
                Text(manager.pairingCode ?? "").font(.title.monospaced())
                Button("取消") { manager.stop() }
            }.padding(24).frame(width: 520, height: 240)
                .task {
                    let authorization = CLLocationManager().authorizationStatus.rawValue
                    let enabled = CLLocationManager.locationServicesEnabled()
                    let diagnostic = await Task.detached { () -> String in
                        let networks = try? CWWiFiClient.shared().interface()?.scanForNetworks(withName: nil)
                        return "location=\(enabled), authorization=\(authorization), scans=\(networks?.count ?? -1), readableNames=\(networks?.filter { $0.ssid != nil }.count ?? -1)"
                    }.value
                    try? diagnostic.write(toFile: "/tmp/diary-nearby-wifi-diagnostic.txt", atomically: true, encoding: .utf8)
                    manager.start(store: store)
                    let file = URL(fileURLWithPath: "/tmp/diary-nearby-wireless-status.json")
                    for _ in 0..<2400 {
                        let value: [String: Any] = ["status": manager.status, "code": manager.pairingCode ?? "", "busy": manager.isBusy, "waiting": manager.isWaiting]
                        try? JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
                        if let code = manager.pairingCode,
                           (try? String(contentsOfFile: "/tmp/diary-nearby-wireless-confirm", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == code {
                            try? FileManager.default.removeItem(atPath: "/tmp/diary-nearby-wireless-confirm")
                            manager.confirm()
                        }
                        if manager.status == "已完成附近同步。" {
                            let files = try! SyncFileStore(directory: root).scan(root: root).data
                            precondition(files["entries/2026/11/17/2026-11-17-1.md"] == wirelessDoc(1, "Wireless Android A"))
                            precondition(files["entries/2026/11/17/2026-11-17-2.md"] == wirelessDoc(2, "Wireless Mac B"))
                            try? "PASS: BLE discovery, matched ECDH code, Wi-Fi Direct, TCP transfer and network release".write(toFile: "/tmp/diary-nearby-wireless-result.txt", atomically: true, encoding: .utf8)
                            try? FileManager.default.removeItem(at: root)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    manager.stop()
                }
        }
    }
}

private func wirelessDoc(_ n: Int, _ body: String) -> Data { Data("---\nid: 2026-11-17-\(n)\ndate: 2026-11-17\ntitle: 附近同步检查\n---\n\(body)".utf8) }
