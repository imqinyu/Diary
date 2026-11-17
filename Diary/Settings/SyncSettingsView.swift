import AppKit
import SwiftUI

struct SyncSettingsView: View {
    @Environment(SyncManager.self) private var sync
    @Environment(DiaryStore.self) private var store
    @State private var selectedRepositoryID: Int?
    @State private var newRepositoryName = "Diary-Private"
    @State private var pendingRepository: GitHubRepository?
    @State private var pendingConflict: SyncConflict?
    @State private var confirmingDisconnect = false

    var body: some View {
        SettingsForm {
            NearbySettingsSection()
            SettingsSection("GitHub 账号") {
                if let account = sync.account {
                    HStack {
                        Label(account.login, systemImage: "person.crop.circle")
                        Spacer()
                        if sync.requiresLogin { Button("重新登录") { sync.beginLogin() } }
                        Button("退出登录…") { confirmingDisconnect = true }
                            .disabled(sync.isBusy || sync.isLoggingIn)
                    }
                } else if !sync.isLoggingIn {
                    Text("把日记和图片同步到自己的 GitHub 私有仓库，历史版本由 Git 提交保留。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("登录 GitHub…") { sync.beginLogin() }
                        .disabled(sync.isBusy)
                }
                if sync.isLoggingIn {
                    if let code = sync.loginCode {
                        Text("在 GitHub 输入下面的验证码完成授权：")
                            .font(.callout)
                        Text(code.user_code)
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        HStack {
                            Button("打开 GitHub 授权页") { sync.openLoginPage() }
                            Button("复制验证码") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code.user_code, forType: .string)
                            }
                            Button("取消") { sync.cancelLogin() }
                        }
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("正在连接 GitHub…"); Button("取消") { sync.cancelLogin() } }
                    }
                }
                Text("访问授权保存在这台 Mac 的钥匙串里，日记仓库中不会包含登录凭据。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if sync.account != nil && !sync.requiresLogin {
                SettingsSection("私有仓库") {
                    if let repo = sync.repository {
                        Label(repo.full_name, systemImage: "lock.rectangle")
                            .font(.callout).textSelection(.enabled)
                        Text("分支：\(repo.default_branch)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Picker("仓库", selection: $selectedRepositoryID) {
                            Text("选择一个私有仓库").tag(nil as Int?)
                            ForEach(sync.repositories) { repo in Text(repo.full_name).tag(Optional(repo.id)) }
                        }
                        Button("刷新") { Task { await sync.refreshRepositories() } }
                            .disabled(sync.isBusy)
                    }
                    Button("使用所选仓库…") {
                        pendingRepository = sync.repositories.first { $0.id == selectedRepositoryID }
                    }
                    .disabled(sync.isBusy || selectedRepositoryID == nil)
                    DisclosureGroup("新建私有仓库") {
                        HStack {
                            TextField("仓库名称", text: $newRepositoryName)
                            Button("创建") {
                                Task {
                                    if let repo = await sync.createRepository(name: newRepositoryName) {
                                        selectedRepositoryID = repo.id
                                        pendingRepository = repo
                                    }
                                }
                            }.disabled(sync.isBusy || newRepositoryName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Text("只同步 entries 文件夹中的日记和图片。隐藏日记的正文和图片一起加密，标题和日期等元数据仍为明文。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsSection("同步状态") {
                HStack {
                    Label(sync.status, systemImage: sync.isBusy ? "arrow.triangle.2.circlepath" : "icloud")
                        .font(.callout)
                    Spacer()
                    if sync.isBusy { ProgressView().controlSize(.small) }
                }
                if let date = sync.lastSyncDate {
                    Text("上次同步：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("自动同步", isOn: Binding(get: { sync.automaticSync }, set: { sync.automaticSync = $0 }))
                    .disabled(!sync.canSync)
                HStack {
                    Button("立即同步") { Task { await sync.syncNow(store: store) } }
                        .disabled(!sync.canSync || sync.isBusy)
                    if let repo = sync.repository,
                       let url = URL(string: "https://github.com/\(repo.full_name)") {
                        Link("在 GitHub 中查看", destination: url)
                    }
                }
                Text("启动时检查，保存后等待 30 秒合并同步，运行期间每 5 分钟检查更新。离线时继续在本机写，联网后重试。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = sync.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !sync.conflicts.isEmpty {
                SettingsSection("需要处理的冲突") {
                    Text("双方版本已另存到这台 Mac。选择后再次同步；远端若又有修改，会重新确认。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(sync.conflicts) { conflict in
                        HStack {
                            Text(conflict.path).font(.callout).lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button(sync.unresolvedConflicts.contains(where: { $0.id == conflict.id }) ? "处理…" : "已选择…") {
                                pendingConflict = conflict
                            }.disabled(sync.isBusy)
                        }
                    }
                }
            }
        }
        .task { if sync.account != nil && !sync.requiresLogin { await sync.refreshRepositories() } }
        .confirmationDialog("使用这个私有仓库同步日记？", isPresented: Binding(
            get: { pendingRepository != nil }, set: { if !$0 { pendingRepository = nil } }
        )) {
            Button("连接并同步") {
                guard let repo = pendingRepository else { return }
                pendingRepository = nil
                Task { await sync.bind(repo, store: store) }
            }
            Button("取消", role: .cancel) { pendingRepository = nil }
        } message: {
            Text("\(pendingRepository?.full_name ?? "")\n将同步本机日记与图片，包括隐私条目的磁盘文件。不同文件会合并，同一文件的不同修改会保留双方版本供你选择。")
        }
        .confirmationDialog("退出 GitHub 登录？", isPresented: $confirmingDisconnect) {
            Button("退出登录", role: .destructive) { sync.disconnect() }
            Button("取消", role: .cancel) {}
        } message: { Text("本机日记、GitHub 仓库和已保留的冲突版本都会保留。") }
        .sheet(item: $pendingConflict) { conflict in
            SyncConflictView(conflict: conflict)
        }
    }
}

private struct SyncConflictView: View {
    let conflict: SyncConflict
    @Environment(SyncManager.self) private var sync
    @Environment(PrivacyManager.self) private var privacy
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择保留的版本").font(.headline)
            Text(conflict.path).font(.callout).textSelection(.enabled)
            HStack(alignment: .top, spacing: 16) {
                version(.local, title: "本机")
                version(.remote, title: "GitHub")
            }
            HStack {
                Button("在访达中显示双方原文件") { sync.revealConflict(conflict) }
                Spacer()
                Button("稍后处理", role: .cancel) { dismiss() }
            }
        }
        .padding(20).frame(width: 720)
    }

    private func version(_ choice: SyncChoice, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                if let data = sync.conflictData(conflict, choice: choice) {
                    if conflict.path.hasSuffix(".md"), let text = String(data: data, encoding: .utf8) {
                        let document = EntryDocument.decode(text)
                        if document.frontMatter.bool("private") == true && privacy.isLocked {
                            Text("隐私日记，请先在搜索框解锁后查看内容。")
                        } else if let entry = DiaryEntry(document: document, fileURL: URL(fileURLWithPath: conflict.path),
                                                       keyResolver: { privacy.encryptionKey(for: $0) }) {
                            Text(entry.title.isEmpty ? DayKey.display(entry.dayKey) : entry.title).font(.subheadline.weight(.semibold))
                            Text("最后编辑：\(entry.updated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.isEncrypted && entry.bodyMarkdown.isEmpty ? "正文已加密或无法解密" : entry.bodyMarkdown)
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    } else if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else { Text("文件大小：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))") }
                } else if (choice == .local ? conflict.localSHA : conflict.remoteSHA) != nil {
                    Text("版本副本无法读取，请重新同步。").foregroundStyle(.secondary)
                } else { Text("这个版本已删除文件").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 300, alignment: .topLeading)
            .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 8))
            Button("使用\(title)版本") { sync.resolve(conflict, choice: choice); dismiss() }
                .disabled(sync.isBusy || ((choice == .local ? conflict.localSHA : conflict.remoteSHA) != nil && sync.conflictData(conflict, choice: choice) == nil))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
