import SwiftUI

struct NearbySettingsSection: View {
    @Environment(NearbyManager.self) private var nearby
    @Environment(DiaryStore.self) private var store
    @Environment(SyncManager.self) private var github
    var body: some View {
        SettingsSection("附近同步") {
            Text("与附近安卓直接同步日记和图片，无需互联网或连接同一个路由器。两端开启蓝牙与 Wi-Fi，再核对配对码。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(nearby.status).font(.callout)
            if let date = nearby.lastSyncDate { Text("上次同步 \(date)").font(.callout).foregroundStyle(.secondary) }
            HStack {
                if nearby.isBusy || nearby.isWaiting {
                    ProgressView().controlSize(.small)
                    Button("取消") { nearby.stop() }
                } else {
                    Button("开启附近同步") { nearby.start(store: store) }.disabled(github.isBusy)
                }
            }
            Text("Mac 会临时接入安卓建立的直连网络；完成后释放连接，由系统恢复网络。macOS 查找 Wi-Fi 需要定位权限。隐藏日记保持加密。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(nearby.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.path.components(separatedBy: "/").last ?? conflict.path).font(.callout)
                    HStack {
                        Button("保留 Mac") { nearby.resolve(conflict, choice: .local) }
                        Button("保留安卓") { nearby.resolve(conflict, choice: .remote) }
                    }.disabled(nearby.isBusy)
                }
            }
        }
        .alert("确认你的安卓设备", isPresented: Binding(get: { nearby.pairingCode != nil }, set: { if !$0 && nearby.pairingCode != nil { nearby.stop() } })) {
            Button("配对码一致") { nearby.confirm() }
            Button("取消", role: .cancel) { nearby.stop() }
        } message: {
            Text("配对码：\(nearby.pairingCode ?? "")\n请确认安卓上的配对码相同，再在两端确认。")
        }
    }
}
