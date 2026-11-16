import AppKit
import Foundation
import SwiftUI

final class MemorySyncCredentials: SyncCredentialStore {
    var token: String?
    func read() throws -> String? { token }
    func save(_ token: String) throws { self.token = token }
    func remove() throws { token = nil }
}

actor FakeGitHub: GitHubSyncAPI {
    let repo = GitHubRepository(id: 12, name: "Diary-Private", full_name: "tester/Diary-Private", private: true,
                                default_branch: "main", permissions: .init(push: true))
    var files: [String: Data] = [:]
    var head = "commit-1"
    var publishes = 0
    var offline = false
    var publicRepository = false
    var publishHook: (@Sendable () async -> Void)?
    func account(token: String) async throws -> GitHubAccount { GitHubAccount(login: "tester") }
    func repositories(token: String) async throws -> [GitHubRepository] { [repo] }
    func repository(owner: String, name: String, token: String) async throws -> GitHubRepository {
        if offline { throw URLError(.notConnectedToInternet) }
        if publicRepository { throw GitHubError.unsafeRepository }
        return repo
    }
    func createRepository(name: String, token: String) async throws -> GitHubRepository { repo }
    func snapshot(repository: GitHubRepository, token: String) async throws -> GitHubRemoteSnapshot {
        if offline { throw URLError(.notConnectedToInternet) }
        return GitHubRemoteSnapshot(commit: head, tree: "tree", files: files.filter { SyncPath.isAllowed($0.key) }.mapValues(SyncHash.blob))
    }
    func blob(sha: String, repository: GitHubRepository, token: String) async throws -> Data {
        guard let data = files.values.first(where: { SyncHash.blob($0) == sha }) else { throw GitHubError.invalidData }
        return data
    }
    func publish(files changes: [String: Data?], parent: GitHubRemoteSnapshot, repository: GitHubRepository, token: String) async throws -> String {
        let hook = publishHook
        publishHook = nil
        await hook?()
        if publicRepository { throw GitHubError.unsafeRepository }
        guard parent.commit == head else { throw GitHubError.branchChanged }
        for (path, data) in changes { files[path] = data }
        publishes += 1
        head = "commit-\(publishes + 100)"
        return head
    }
    func setFile(_ path: String, _ data: Data?) { files[path] = data; head += "-external" }
    func contents(_ path: String) -> Data? { files[path] }
    func setOffline(_ value: Bool) { offline = value }
    func setPublic(_ value: Bool) { publicRepository = value }
    func onPublish(_ hook: @escaping @Sendable () async -> Void) { publishHook = hook }
    func count() -> Int { publishes }
}

final class MockGitHubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct SyncChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        checkMerge()
        try await checkAPI()
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("DiarySyncChecks-\(UUID().uuidString)")
        let root = workspace.appendingPathComponent("Diary")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(["DiaryDataRootPath": root.path], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let suite = "DiarySyncChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyManager(defaults: defaults, auditLog: PrivacyAuditLog(fileURL: workspace.appendingPathComponent("audit.json")))
        let store = DiaryStore(privacy: privacy)
        let server = FakeGitHub()
        let credentials = MemorySyncCredentials()
        let syncDirectory = workspace.appendingPathComponent("SyncState")
        let sync = SyncManager(defaults: defaults, api: server, credentials: credentials, directory: syncDirectory)
        sync.start(store: store)
        defer { sync.stop() }
        try await sync.signIn(token: "dummy-test-token")
        let entry = store.createTodayEntry()!
        store.saveBody(entryID: entry.id, markdown: "original")
        let path = "entries/" + DayKey.today().replacingOccurrences(of: "-", with: "/") + "/" + entry.fileURL.lastPathComponent
        await server.setFile("README.md", Data("unrelated repository file".utf8))
        await sync.bind(server.repo, store: store)
        precondition(sync.status == "已同步" && sync.errorMessage == nil)
        let firstRemote = await server.contents(path)
        precondition(firstRemote == (try? Data(contentsOf: entry.fileURL)))
        let readme = await server.contents("README.md")
        precondition(readme == Data("unrelated repository file".utf8))
        let persisted = try PropertyListSerialization.data(fromPropertyList: defaults.persistentDomain(forName: suite) ?? [:], format: .xml, options: 0)
        precondition(!String(decoding: persisted, as: UTF8.self).contains("dummy-test-token"))

        // 拉取不会破坏编辑器里还没到自动保存时间的输入。
        try checkEditorFlush(store: store, entry: store.entry(with: entry.id)!, privacy: privacy, defaults: defaults)
        await sync.syncNow(store: store)
        var remoteDocument = try EntryDocument.read(from: entry.fileURL)
        remoteDocument.body = "remote update"
        await server.setFile(path, Data(remoteDocument.encode().utf8))
        let generation = store.externalReloadGeneration
        await sync.syncNow(store: store)
        precondition(store.entry(with: entry.id)?.bodyMarkdown == "remote update")
        precondition(store.externalReloadGeneration > generation)

        // 同一文件双方修改，先留双方副本，用户选择后才覆盖。
        store.saveBody(entryID: entry.id, markdown: "local conflict")
        remoteDocument.body = "remote conflict"
        await server.setFile(path, Data(remoteDocument.encode().utf8))
        await sync.syncNow(store: store)
        precondition(sync.conflicts.count == 1 && store.entry(with: entry.id)?.bodyMarkdown == "local conflict")
        let conflict = sync.conflicts[0]
        precondition(String(decoding: sync.conflictData(conflict, choice: .local)!, as: UTF8.self).contains("local conflict"))
        precondition(String(decoding: sync.conflictData(conflict, choice: .remote)!, as: UTF8.self).contains("remote conflict"))
        sync.resolve(conflict, choice: .remote)
        remoteDocument.body = "remote changed again"
        await server.setFile(path, Data(remoteDocument.encode().utf8))
        await sync.syncNow(store: store)
        precondition(sync.conflicts.count == 1 && !sync.unresolvedConflicts.isEmpty)
        precondition(store.entry(with: entry.id)?.bodyMarkdown == "local conflict")
        sync.resolve(sync.conflicts[0], choice: .remote)
        await sync.syncNow(store: store)
        precondition(sync.conflicts.isEmpty && store.entry(with: entry.id)?.bodyMarkdown == "remote changed again")

        // 只处理部分冲突后手动同步，之前有效的选择仍保留。
        let secondConflictEntry = store.createTodayEntry()!
        store.saveBody(entryID: secondConflictEntry.id, markdown: "second baseline")
        await sync.syncNow(store: store)
        let secondPath = "entries/" + DayKey.today().replacingOccurrences(of: "-", with: "/") + "/" + secondConflictEntry.fileURL.lastPathComponent
        var secondRemote = try EntryDocument.read(from: secondConflictEntry.fileURL)
        store.saveBody(entryID: entry.id, markdown: "first local choice")
        store.saveBody(entryID: secondConflictEntry.id, markdown: "second local choice")
        remoteDocument.body = "first remote choice"
        secondRemote.body = "second remote choice"
        await server.setFile(path, Data(remoteDocument.encode().utf8))
        await server.setFile(secondPath, Data(secondRemote.encode().utf8))
        await sync.syncNow(store: store)
        precondition(sync.conflicts.count == 2)
        sync.resolve(sync.conflicts.first { $0.path == path }!, choice: .remote)
        await sync.syncNow(store: store)
        precondition(sync.conflicts.count == 2 && sync.unresolvedConflicts.count == 1)
        precondition(sync.unresolvedConflicts[0].path == secondPath)
        sync.resolve(sync.unresolvedConflicts[0], choice: .local)
        await sync.syncNow(store: store)
        precondition(sync.conflicts.isEmpty && store.entry(with: entry.id)?.bodyMarkdown == "first remote choice")
        precondition(store.entry(with: secondConflictEntry.id)?.bodyMarkdown == "second local choice")

        // 上传过程中继续编辑，不会产生与自己上一次保存的冲突，也不会丢内容。
        store.saveBody(entryID: entry.id, markdown: "before upload")
        await server.onPublish { await MainActor.run { store.saveBody(entryID: entry.id, markdown: "typed while uploading") } }
        await sync.syncNow(store: store)
        precondition(store.entry(with: entry.id)?.bodyMarkdown == "typed while uploading" && sync.conflicts.isEmpty)
        await sync.syncNow(store: store)
        let afterTyping = await server.contents(path)!
        precondition(EntryDocument.decode(String(decoding: afterTyping, as: UTF8.self)).body == "typed while uploading")

        // 拉取同一文件的新版本时又编辑本机，双方版本必须变成冲突。
        remoteDocument.body = "remote during download"
        await server.setFile(path, Data(remoteDocument.encode().utf8))
        let other = store.createTodayEntry()!
        store.saveBody(entryID: other.id, markdown: "independent page")
        await server.onPublish { await MainActor.run { store.saveBody(entryID: entry.id, markdown: "local during download") } }
        await sync.syncNow(store: store)
        precondition(sync.conflicts.count == 1 && store.entry(with: entry.id)?.bodyMarkdown == "local during download")
        sync.resolve(sync.conflicts[0], choice: .local)
        await sync.syncNow(store: store)
        precondition(sync.conflicts.isEmpty)

        // 远端分支同时前进时重新拉取合并，禁止强推丢掉另一台机器的提交。
        store.saveBody(entryID: other.id, markdown: "local independent update")
        let remotePath = "entries/2024/06/10/2024-06-10-1.md"
        let remotePage = EntryDocument.decode("---\nid: 2024-06-10-1\ndate: 2024-06-10\nupdated: 2026-11-16T08:00:00Z\n---\n\nother device")
        await server.onPublish { await server.setFile(remotePath, Data(remotePage.encode().utf8)) }
        await sync.syncNow(store: store)
        precondition(sync.errorMessage == nil && store.entry(with: "2024-06-10-1")?.bodyMarkdown == "other device")

        // 离线保留本机修改；恢复联网后继续推送。
        await server.setOffline(true)
        store.saveBody(entryID: other.id, markdown: "written offline")
        await sync.syncNow(store: store)
        precondition(sync.status == "等待联网" && store.entry(with: other.id)?.bodyMarkdown == "written offline")
        await server.setOffline(false)
        await sync.syncNow(store: store)
        precondition(sync.errorMessage == nil)

        // 私密正文只上传密文；不同设备各自的密码盐也能解密同一篇日记。
        precondition(privacy.setPassword("shared-private-password"))
        let privateEntry = store.createTodayEntry()!
        store.saveBody(entryID: privateEntry.id, markdown: "private content must stay encrypted")
        store.updatePrivacy(entryID: privateEntry.id, isPrivate: true)
        store.updateTags(entryID: privateEntry.id, tags: ["temporary-private-tag"])
        precondition(store.removeTag("temporary-private-tag") == 1)
        var privateDoc = try EntryDocument.read(from: privateEntry.fileURL)
        precondition(privateDoc.frontMatter.bool("encrypted") == true && !privateDoc.body.contains("private content must stay encrypted"))
        let cipherBefore = privateDoc.body
        privateDoc.frontMatter.set("encryption_salt", nil)
        try privateDoc.write(to: privateEntry.fileURL)
        privacy.lock()
        store.reload()
        do { try store.prepareForSync(); preconditionFailure("Stamped unverified legacy ciphertext") }
        catch DiarySyncError.unlockLegacyEncryption {}
        let unchangedLegacy = try Data(contentsOf: privateEntry.fileURL)
        precondition(unchangedLegacy == Data(privateDoc.encode().utf8))
        let unlocked = await privacy.tryUnlock("shared-private-password")
        precondition(unlocked)
        store.reload()
        try store.prepareForSync()
        privateDoc = try EntryDocument.read(from: privateEntry.fileURL)
        precondition(privateDoc.body == cipherBefore && privateDoc.frontMatter.string("encryption_salt") == privacy.encryptionSalt)
        await sync.syncNow(store: store)
        let privatePath = "entries/" + DayKey.today().replacingOccurrences(of: "-", with: "/") + "/" + privateEntry.fileURL.lastPathComponent
        let privateRemote = await server.contents(privatePath)!
        precondition(!String(decoding: privateRemote, as: UTF8.self).contains("private content must stay encrypted"))
        let otherSuite = "DiaryOtherDevice.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let otherPrivacy = PrivacyManager(defaults: otherDefaults, auditLog: PrivacyAuditLog(fileURL: workspace.appendingPathComponent("other-audit.json")))
        precondition(otherPrivacy.setPassword("shared-private-password"))
        precondition(otherPrivacy.encryptionSalt != privacy.encryptionSalt)
        let opened = DiaryEntry(document: privateDoc, fileURL: privateEntry.fileURL, keyResolver: { otherPrivacy.encryptionKey(for: $0) })!
        precondition(opened.bodyMarkdown == "private content must stay encrypted" && opened.isContentAvailable)
        otherPrivacy.lock()
        let unopened = DiaryEntry(document: privateDoc, fileURL: privateEntry.fileURL, keyResolver: { otherPrivacy.encryptionKey(for: $0) })!
        precondition(!unopened.isContentAvailable && !unopened.isWritable)
        privacy.lock()
        store.reload()
        await sync.syncNow(store: store)
        precondition(sync.errorMessage == nil) // 锁定状态仍可同步已经加密的原文件。

        // 本机删除会传播到远端；远端删除也移除本机原文件。
        precondition(store.deleteEntry(entryID: other.id))
        await sync.syncNow(store: store)
        let otherPath = "entries/" + DayKey.today().replacingOccurrences(of: "-", with: "/") + "/" + other.fileURL.lastPathComponent
        let deletedRemote = await server.contents(otherPath)
        precondition(deletedRemote == nil)
        await server.setFile(path, nil)
        await sync.syncNow(store: store)
        precondition(store.entry(with: entry.id) == nil)

        // 仓库变成公开时任何本机变更都不上传。
        let confidential = store.createTodayEntry()!
        store.saveBody(entryID: confidential.id, markdown: "must remain local")
        let countBefore = await server.count()
        await server.setPublic(true)
        await sync.syncNow(store: store)
        let countAfter = await server.count()
        precondition(countBefore == countAfter && sync.errorMessage != nil)
        await server.setPublic(false)

        // 本机符号链接不能把目录外的文件带到 GitHub。
        let outside = workspace.appendingPathComponent("secret")
        try Data("outside file".utf8).write(to: outside)
        let link = store.entriesDirectory.appendingPathComponent("leak")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        await sync.syncNow(store: store)
        let countAfterLink = await server.count()
        precondition(countAfterLink == countBefore && sync.errorMessage != nil)
        try fm.removeItem(at: link)
        await sync.syncNow(store: store)
        precondition(sync.errorMessage == nil)

        // 原子目录交换之前发现新的磁盘写入，必须保持这些新内容。
        let disk = SyncFileStore(directory: syncDirectory)
        let corruptState = SyncFileStore(directory: workspace.appendingPathComponent("corrupt-state"))
        try corruptState.saveState(SyncState(files: ["entries/page.md": "invalid-hash"]))
        do { _ = try corruptState.loadState(); preconditionFailure("Accepted corrupt baseline") }
        catch DiarySyncError.invalidState {}
        let caseRoot = workspace.appendingPathComponent("case-root")
        try fm.createDirectory(at: caseRoot.appendingPathComponent("entries"), withIntermediateDirectories: true)
        let caseFiles = ["entries/assets/photo.png": Data("first".utf8), "entries/assets/PHOTO.png": Data("second".utf8)]
        do {
            _ = try disk.apply(files: caseFiles, expected: [:], root: caseRoot)
            let scannedCaseFiles = try disk.scan(root: caseRoot)
            precondition(scannedCaseFiles.data == caseFiles)
        } catch DiarySyncError.invalidState {
            let preserved = try disk.scan(root: caseRoot)
            precondition(preserved.data.isEmpty)
        }
        let original = try disk.scan(root: root)
        store.saveBody(entryID: confidential.id, markdown: "changed after snapshot")
        do {
            var altered = original.data
            let currentPath = "entries/" + DayKey.today().replacingOccurrences(of: "-", with: "/") + "/" + confidential.fileURL.lastPathComponent
            var overwrite = EntryDocument.decode(String(decoding: altered[currentPath]!, as: UTF8.self))
            overwrite.body = "would overwrite newer local contents"
            altered[currentPath] = Data(overwrite.encode().utf8)
            _ = try disk.apply(files: altered, expected: original.hashes, root: root)
            preconditionFailure("Overwrote a newer local change")
        } catch DiarySyncError.localChanged {}
        precondition(store.entry(with: confidential.id)?.bodyMarkdown == "changed after snapshot")
        print("PASS: GitHub device flow/API, private repositories, git hashes, merge/deletions, persisted credentials separation, editor flush, conflicts and stale choices, concurrent editing, branch races, offline retry, path protection, and atomic disk update")
    }

    static func checkMerge() {
        precondition(SyncHash.blob(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        let path = "entries/one.md"
        precondition(SyncMerge.plan(base: [path: "a"], local: [:], remote: [path: "a"]).files.isEmpty)
        precondition(SyncMerge.plan(base: [path: "a"], local: [path: "a"], remote: [:]).files.isEmpty)
        precondition(SyncMerge.plan(base: [path: "a"], local: [:], remote: [path: "b"]).conflicts == [path])
        precondition(SyncMerge.plan(base: [:], local: [path: "a"], remote: [path: "b"]).conflicts == [path])
        let choice = SyncResolution(localSHA: nil, remoteSHA: "b", choice: .local)
        precondition(SyncMerge.plan(base: [path: "a"], local: [:], remote: [path: "b"], resolutions: [path: choice]).conflicts.isEmpty)
        for path in ["entries/../secret", "entries//file", "entries/.hidden", "/entries/file", "settings/token", "entries/a\\b"] {
            precondition(!SyncPath.isAllowed(path))
        }
    }

    @MainActor
    static func checkAPI() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MockGitHubProtocol.handler = nil }
        let client = GitHubClient(session: session)
        let blob = Data("sample".utf8), sha = SyncHash.blob(Data("sample".utf8))
        let repoJSON: [String: Any] = ["id": 12, "name": "Diary-Private", "full_name": "tester/Diary-Private",
                                      "private": true, "default_branch": "main", "permissions": ["push": true]]
        var sawForceFalse = false, sawDeletion = false, sawBootstrap = false
        var treeMode = "normal", isPrivate = true, emptyRepo = false, hasBranches = false, corruptBlob = false
        MockGitHubProtocol.handler = { request in
            var requestData = request.httpBody ?? Data()
            if requestData.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    requestData.append(contentsOf: bytes.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]) ?? [:]
            switch request.url!.path {
            case "/login/device/code":
                precondition(body["client_id"] as? String == GitHubClient.clientID && body["scope"] as? String == "repo")
                precondition(body["client_secret"] == nil)
                return (200, ["device_code": "test-device", "user_code": "TEST-CODE", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5])
            case "/login/oauth/access_token":
                precondition(body["client_secret"] == nil)
                if body["grant_type"] as? String == "refresh_token" {
                    precondition(body["refresh_token"] as? String == "old-refresh")
                    return (200, ["access_token": "renewed-token", "refresh_token": "renewed-refresh", "expires_in": 28800])
                }
                precondition(body["grant_type"] as? String == "urn:ietf:params:oauth:grant-type:device_code")
                return (200, ["error": "slow_down", "interval": 10])
            case "/repos/tester/Diary-Private":
                var value = repoJSON
                value["private"] = isPrivate
                return (200, value)
            case "/repos/tester/Diary-Private/git/ref/heads/main":
                return emptyRepo ? (409, [:]) : (200, ["object": ["sha": "old"]])
            case "/repos/tester/Diary-Private/branches": return (200, hasBranches ? [["name": "other-branch"]] : [])
            case "/repos/tester/Diary-Private/contents/README.md":
                precondition(request.httpMethod == "PUT" && body["sha"] == nil)
                sawBootstrap = true
                return (201, ["commit": ["sha": "initial"]])
            case "/repos/tester/Diary-Private/git/commits/old": return (200, ["tree": ["sha": "old-tree"]])
            case "/repos/tester/Diary-Private/git/trees/old-tree":
                return (200, ["truncated": treeMode == "truncated", "tree": [["path": treeMode == "unsafe" ? "entries/../leak" : "entries/page.md", "type": "blob", "mode": treeMode == "symlink" ? "120000" : "100644", "sha": sha],
                                                         ["path": "README.md", "type": "blob", "mode": "100644", "sha": "other"]]])
            case "/repos/tester/Diary-Private/git/blobs/\(sha)": return (200, ["encoding": "base64", "content": (corruptBlob ? Data("corrupt".utf8) : blob).base64EncodedString()])
            case "/repos/tester/Diary-Private/git/blobs": return (201, ["sha": sha])
            case "/repos/tester/Diary-Private/git/trees":
                precondition(body["base_tree"] as? String == "old-tree")
                let tree = body["tree"] as! [[String: Any]]
                sawDeletion = tree.contains { $0["path"] as? String == "entries/deleted.md" && $0["sha"] is NSNull }
                return (201, ["sha": "new-tree"])
            case "/repos/tester/Diary-Private/git/commits":
                precondition(body["parents"] as? [String] == ["old"])
                return (201, ["sha": "new-commit"])
            case "/repos/tester/Diary-Private/git/refs/heads/main":
                sawForceFalse = body["force"] as? Bool == false
                return (200, ["ref": "refs/heads/main"])
            default: throw GitHubError.invalidData
            }
        }
        let device = try await client.beginLogin()
        let polling = try await client.pollLogin(code: device)
        precondition(polling.error == "slow_down" && polling.interval == 10)
        let repo = try await client.repository(owner: "tester", name: "Diary-Private", token: "test-token")
        let snapshot = try await client.snapshot(repository: repo, token: "test-token")
        precondition(snapshot.files.count == 1 && snapshot.files["README.md"] == nil)
        let downloaded = try await client.blob(sha: sha, repository: repo, token: "test-token")
        precondition(downloaded == blob)
        var files: [String: Data?] = ["entries/page.md": blob]
        files.updateValue(nil, forKey: "entries/deleted.md")
        _ = try await client.publish(files: files, parent: snapshot, repository: repo, token: "test-token")
        precondition(sawDeletion && sawForceFalse)
        treeMode = "truncated"
        do { _ = try await client.snapshot(repository: repo, token: "test-token"); preconditionFailure("Accepted truncated tree") }
        catch GitHubError.truncatedTree {}
        for mode in ["symlink", "unsafe"] {
            treeMode = mode
            do { _ = try await client.snapshot(repository: repo, token: "test-token"); preconditionFailure("Accepted unsafe tree") }
            catch GitHubError.invalidData {}
        }
        treeMode = "normal"
        corruptBlob = true
        do { _ = try await client.blob(sha: sha, repository: repo, token: "test-token"); preconditionFailure("Accepted corrupt blob") }
        catch GitHubError.invalidData {}
        corruptBlob = false
        isPrivate = false
        do { _ = try await client.publish(files: files, parent: snapshot, repository: repo, token: "test-token"); preconditionFailure("Published to public repo") }
        catch GitHubError.unsafeRepository {}
        isPrivate = true
        emptyRepo = true
        let empty = try await client.snapshot(repository: repo, token: "test-token")
        precondition(empty.commit == nil && empty.files.isEmpty)
        do { _ = try await client.publish(files: files, parent: empty, repository: repo, token: "test-token"); preconditionFailure("Skipped bootstrap retry") }
        catch GitHubError.branchChanged {}
        precondition(sawBootstrap)
        hasBranches = true
        do { _ = try await client.snapshot(repository: repo, token: "test-token"); preconditionFailure("Treated removed branch as empty repo") }
        catch GitHubError.branchChanged {}
        emptyRepo = false
        let suite = "DiaryTokenRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(GitHubAccount(login: "tester")), forKey: "GitHubAccount")
        let credentials = MemorySyncCredentials()
        let expired = GitHubSessionCredential(accessToken: "expired", refreshToken: "old-refresh", expiresAt: Date().addingTimeInterval(-1))
        credentials.token = String(decoding: try JSONEncoder().encode(expired), as: UTF8.self)
        let manager = SyncManager(defaults: defaults, api: FakeGitHub(), loginClient: client, credentials: credentials)
        await manager.refreshRepositories()
        let renewed = try JSONDecoder().decode(GitHubSessionCredential.self, from: Data(credentials.token!.utf8))
        precondition(renewed.accessToken == "renewed-token" && renewed.refreshToken == "renewed-refresh")
        precondition(renewed.expiresAt! > Date() && manager.errorMessage == nil)
    }

    @MainActor
    static func checkEditorFlush(store: DiaryStore, entry: DiaryEntry, privacy: PrivacyManager, defaults: UserDefaults) throws {
        let view = EntryDetailView(entry: entry, reloadGeneration: store.externalReloadGeneration)
            .environment(store).environment(privacy).environment(AppPreferences(defaults: defaults)).environment(LocationService())
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        for _ in 0..<4 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        func findText(_ view: NSView) -> NSTextView? {
            if let view = view as? NSTextView { return view }
            return view.subviews.lazy.compactMap(findText).first
        }
        let text = findText(hosting)!
        text.insertText("pending ", replacementRange: NSRange(location: 0, length: 0))
        store.flushEditorsForSync()
        precondition(store.entry(with: entry.id)!.bodyMarkdown.hasPrefix("pending "))
        var document = try EntryDocument.read(from: entry.fileURL)
        document.body = "externally applied version"
        try document.write(to: entry.fileURL)
        store.reloadFromSync()
        window.contentView = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(store.entry(with: entry.id)?.bodyMarkdown == "externally applied version")
    }
}
