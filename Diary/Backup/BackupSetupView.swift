import AppKit
import SwiftUI

/// 首次使用时的强制引导：没有备份位置就不让进主界面。
struct BackupSetupView: View {
    @Environment(BackupManager.self) private var backup
    @Environment(DiaryStore.self) private var store

    @State private var localError: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)

            Text("先挑一个备份位置")
                .font(.title2.bold())

            Text("日记会定期打成一个 zip 放到一个独立文件夹里，iCloud Drive、U 盘、外置硬盘都行。电脑丢了、坏了，日记还能从这儿找回来。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("选择备份文件夹…") {
                chooseFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let message = localError ?? backup.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(36)
        .frame(width: 470)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "用这个文件夹"
        panel.message = "选择用来存放自动备份的文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try backup.setFolder(url, dataRoot: store.dataRoot)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
}
