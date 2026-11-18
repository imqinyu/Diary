import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SyncManager {
    private(set) var account: GitHubAccount?
    private(set) var repository: GitHubRepository?
    private(set) var repositories: [GitHubRepository] = []
    private(set) var isBusy = false
    private(set) var isLoggingIn = false
    private(set) var loginCode: GitHubDeviceCode?
    private(set) var requiresLogin = false
    private(set) var status = "尚未连接 GitHub"
    private(set) var lastSyncDate: Date?
    private(set) var conflicts: [SyncConflict] = []
    var errorMessage: String?
    var automaticSync: Bool {
        didSet {
            defaults.set(automaticSync, forKey: "GitHubAutomaticSync")
            if automaticSync { schedule() } else { scheduledTask?.cancel() }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let api: any GitHubSyncAPI
    @ObservationIgnored private let loginClient: GitHubClient
    @ObservationIgnored private let credentials: any SyncCredentialStore
    @ObservationIgnored private let files: SyncFileStore
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var tokenExpiresAt: Date?
    @ObservationIgnored private weak var store: DiaryStore?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSync = false
    @ObservationIgnored private var boundRoot: String?
    @ObservationIgnored private var space: SyncFileStore?
    @ObservationIgnored private var state = SyncState()
    @ObservationIgnored private var stateIsValid = true

    init(defaults: UserDefaults = .standard, api: any GitHubSyncAPI = GitHubClient(),
         loginClient: GitHubClient = GitHubClient(), credentials: any SyncCredentialStore = KeychainSyncCredentials(),
         directory: URL = SyncFileStore.defaultDirectory(), loadCredentials: Bool = true) {
        self.defaults = defaults
        self.api = api
        self.loginClient = loginClient
        self.credentials = credentials
        self.files = SyncFileStore(directory: directory)
        automaticSync = defaults.object(forKey: "GitHubAutomaticSync") as? Bool ?? false
        boundRoot = defaults.string(forKey: "GitHubSyncRoot")
        if let data = defaults.data(forKey: "GitHubAccount") { account = try? JSONDecoder().decode(GitHubAccount.self, from: data) }
        if let data = defaults.data(forKey: "GitHubRepository") { repository = try? JSONDecoder().decode(GitHubRepository.self, from: data) }
        if loadCredentials {
            do {
                if let saved = try credentials.read() {
                    if let credential = try? JSONDecoder().decode(GitHubSessionCredential.self, from: Data(saved.utf8)) {
                        token = credential.accessToken
                        refreshToken = credential.refreshToken
                        tokenExpiresAt = credential.expiresAt
                    } else if !saved.hasPrefix("{") {
                        token = saved
                    }
                }
            }
            catch { errorMessage = error.localizedDescription }
        }
        requiresLogin = account != nil && token == nil
        if let repository, let boundRoot {
            let namespace = files.namespace(repository: repository, root: URL(fileURLWithPath: boundRoot))
            space = namespace
            do {
                state = try namespace.loadState()
                lastSyncDate = state.lastSyncDate
                conflicts = state.conflicts
                status = conflicts.isEmpty ? "等待同步" : "有 \(conflicts.count) 个冲突需要处理"
            } catch {
                stateIsValid = false
                errorMessage = error.localizedDescription
                status = "同步已暂停"
            }
        }
    }

    var canSync: Bool {
        let rootMatches = store.map { boundRoot == $0.dataRoot.resolvingSymlinksInPath().path } ?? true
        return token != nil && repository != nil && stateIsValid && !requiresLogin && rootMatches
    }
    var unresolvedConflicts: [SyncConflict] { conflicts.filter { state.resolutions[$0.path] == nil } }

    func start(store: DiaryStore) {
        self.store = store
        store.onDiskChange = { [weak self, weak store] in
            guard let self, let store else { return }
            if let boundRoot = self.boundRoot, boundRoot != store.dataRoot.resolvingSymlinksInPath().path {
                self.automaticSync = false
                self.status = DiarySyncError.rootChanged.localizedDescription
                self.errorMessage = self.status
                return
            }
            self.schedule()
        }
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            if let self, self.automaticSync { await self.syncNow(store: store) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30 * 60)) } catch { return }
                guard let self else { return }
                if self.automaticSync && self.unresolvedConflicts.isEmpty { await self.syncNow(store: store) }
            }
        }
    }

    func stop() {
        cancelLogin()
        scheduledTask?.cancel()
        periodicTask?.cancel()
        periodicTask = nil
        store?.onDiskChange = nil
        store = nil
    }

    func schedule() {
        guard automaticSync, canSync, unresolvedConflicts.isEmpty, store != nil else { return }
        if !isBusy { status = "本机已保存，等待每半小时同步" }
    }

    func beginLogin() {
        guard !isBusy, !isLoggingIn else { return }
        isLoggingIn = true
        errorMessage = nil
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoggingIn = false; self.loginCode = nil }
            do {
                let code = try await loginClient.beginLogin()
                try Task.checkCancellation()
                loginCode = code
                let deadline = Date().addingTimeInterval(Double(code.expires_in))
                var interval = max(5, code.interval)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    let result = try await loginClient.pollLogin(code: code)
                    try Task.checkCancellation()
                    if let token = result.access_token {
                        try await signIn(token: token, refreshToken: result.refresh_token, expiresIn: result.expires_in)
                        return
                    }
                    switch result.error {
                    case "authorization_pending": break
                    case "slow_down": interval = max(interval + 5, result.interval ?? 0)
                    default: throw GitHubError.authorization(result.error ?? "unknown")
                    }
                }
                throw GitHubError.authorization("expired_token")
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openLoginPage() {
        guard let code = loginCode, let url = URL(string: code.verification_uri),
              url.scheme == "https", url.host == "github.com" else { return }
        NSWorkspace.shared.open(url)
    }

    func cancelLogin() { loginTask?.cancel() }

    func signIn(token: String, refreshToken: String? = nil, expiresIn: Int? = nil) async throws {
        let account = try await api.account(token: token)
        try Task.checkCancellation()
        try saveCredential(accessToken: token, refreshToken: refreshToken,
                           expiresAt: expiresIn.map { Date().addingTimeInterval(Double($0)) })
        if self.account?.login != account.login {
            repository = nil
            boundRoot = nil
            space = nil
            state = SyncState()
            conflicts = []
            lastSyncDate = nil
            automaticSync = false
            defaults.removeObject(forKey: "GitHubRepository")
            defaults.removeObject(forKey: "GitHubSyncRoot")
        }
        self.token = token
        self.account = account
        requiresLogin = false
        defaults.set(try JSONEncoder().encode(account), forKey: "GitHubAccount")
        status = repository == nil ? "请选择私有仓库" : "等待同步"
        errorMessage = nil
        await refreshRepositories()
        schedule()
    }

    func refreshRepositories() async {
        guard token != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { repositories = try await api.repositories(token: freshToken()); errorMessage = nil }
        catch { report(error) }
    }

    func createRepository(name: String) async -> GitHubRepository? {
        guard token != nil, !isBusy else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            errorMessage = "仓库名请使用英文字母、数字、短横线或下划线"
            return nil
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let repo = try await api.createRepository(name: name, token: freshToken())
            guard repo.canSync else { throw GitHubError.unsafeRepository }
            repositories.insert(repo, at: 0)
            errorMessage = nil
            return repo
        } catch { report(error); return nil }
    }

    func bind(_ repo: GitHubRepository, store: DiaryStore) async {
        guard token != nil, !isBusy else { return }
        isBusy = true
        do {
            let checked = try await api.repository(owner: repo.owner, name: repo.name, token: freshToken())
            guard checked.canSync else { throw GitHubError.unsafeRepository }
            let namespace = files.namespace(repository: checked, root: store.dataRoot)
            let state = try namespace.loadState()
            repository = checked
            boundRoot = store.dataRoot.resolvingSymlinksInPath().path
            space = namespace
            self.state = state
            stateIsValid = true
            conflicts = state.conflicts
            lastSyncDate = state.lastSyncDate
            defaults.set(try JSONEncoder().encode(checked), forKey: "GitHubRepository")
            defaults.set(boundRoot, forKey: "GitHubSyncRoot")
            automaticSync = true
            errorMessage = nil
        } catch { report(error); isBusy = false; return }
        isBusy = false
        await syncNow(store: store)
    }

    func disconnect() {
        guard !isBusy else { return }
        cancelLogin()
        scheduledTask?.cancel()
        do { try credentials.remove() } catch { report(error); return }
        token = nil
        refreshToken = nil
        tokenExpiresAt = nil
        account = nil
        repository = nil
        repositories = []
        space = nil
        boundRoot = nil
        state = SyncState()
        conflicts = []
        requiresLogin = false
        automaticSync = false
        lastSyncDate = nil
        for key in ["GitHubAccount", "GitHubRepository", "GitHubSyncRoot"] { defaults.removeObject(forKey: key) }
        status = "尚未连接 GitHub"
        errorMessage = nil
    }

    func resolve(_ conflict: SyncConflict, choice: SyncChoice) {
        guard !isBusy, let space else { return }
        let sha = choice == .local ? conflict.localSHA : conflict.remoteSHA
        if sha != nil && space.conflictData(conflict, choice: choice) == nil {
            errorMessage = "冲突副本无法读取，请重新同步以获取完整版本"
            return
        }
        var next = state
        next.resolutions[conflict.path] = SyncResolution(localSHA: conflict.localSHA, remoteSHA: conflict.remoteSHA, choice: choice)
        do { try space.saveState(next); state = next; errorMessage = nil; schedule() }
        catch { report(error) }
    }

    func conflictData(_ conflict: SyncConflict, choice: SyncChoice) -> Data? { space?.conflictData(conflict, choice: choice) }
    func revealConflict(_ conflict: SyncConflict) {
        if let space { NSWorkspace.shared.activateFileViewerSelecting([space.conflictDirectory(conflict)]) }
    }

    func syncNow(store: DiaryStore) async {
        guard canSync, let repo = repository, let space else { return }
        guard !isBusy else { pendingSync = true; return }
        guard boundRoot == store.dataRoot.resolvingSymlinksInPath().path else { report(DiarySyncError.rootChanged); return }
        isBusy = true
        pendingSync = false
        errorMessage = nil
        status = "正在检查日记…"
        defer {
            isBusy = false
            if pendingSync { pendingSync = false; schedule() }
        }
        let token: String
        do { token = try await freshToken() } catch { report(error); return }
        for attempt in 0..<3 {
            do {
                try await performSync(store: store, repo: repo, space: space, token: token)
                return
            } catch GitHubError.branchChanged where attempt < 2 {
                status = "远端有更新，正在重新合并…"
            } catch {
                report(error)
                return
            }
        }
    }

    private func performSync(store: DiaryStore, repo: GitHubRepository, space: SyncFileStore, token: String) async throws {
        let root = store.dataRoot
        store.flushEditorsForSync()
        try store.prepareForSync()
        let local = try files.scan(root: root)
        let localHashes = local.hashes
        let checked = try await api.repository(owner: repo.owner, name: repo.name, token: token)
        guard checked.canSync, checked.id == repo.id, checked.default_branch == repo.default_branch else { throw GitHubError.unsafeRepository }
        let remote = try await api.snapshot(repository: repo, token: token)
        let merge = SyncMerge.plan(base: state.files, local: localHashes, remote: remote.files, resolutions: state.resolutions)
        if !merge.conflicts.isEmpty {
            var next = state
            next.conflicts = []
            let allConflicts = SyncMerge.plan(base: state.files, local: localHashes, remote: remote.files).conflicts
            next.resolutions = state.resolutions.filter { path, resolution in
                allConflicts.contains(path) && resolution.localSHA == localHashes[path] && resolution.remoteSHA == remote.files[path]
            }
            for path in allConflicts {
                let data = try await remoteData(path: path, remote: remote, repo: repo, space: space, token: token)
                next.conflicts.append(try space.saveConflict(path: path, local: local.data[path], remote: data))
            }
            try space.saveState(next)
            state = next
            conflicts = next.conflicts
            status = "有 \(conflicts.count) 个冲突需要处理"
            return
        }
        var merged: [String: Data] = [:]
        for path in merge.files.keys.sorted() {
            if localHashes[path] == merge.files[path] { merged[path] = local.data[path] }
            else { merged[path] = try await remoteData(path: path, remote: remote, repo: repo, space: space, token: token) }
        }
        guard merged.mapValues(SyncHash.blob) == merge.files else { throw GitHubError.invalidData }
        try files.validate(merged)
        guard root.resolvingSymlinksInPath() == store.dataRoot.resolvingSymlinksInPath() else { throw DiarySyncError.rootChanged }
        var changes: [String: Data?] = [:]
        for path in Set(remote.files.keys).union(merge.files.keys) where remote.files[path] != merge.files[path] {
            changes.updateValue(merged[path], forKey: path)
        }
        var commit = remote.commit
        if !changes.isEmpty {
            status = "正在上传 \(changes.count) 个文件变更…"
            commit = try await api.publish(files: changes, parent: remote, repository: repo, token: token)
        }
        guard root.resolvingSymlinksInPath() == store.dataRoot.resolvingSymlinksInPath() else { throw DiarySyncError.rootChanged }
        // 网络请求期间继续输入的内容先落盘，再以最初的本机快照做一次三方合并。
        store.flushEditorsForSync()
        let latest = try files.scan(root: root)
        let latestHashes = latest.hashes
        let late = SyncMerge.plan(base: localHashes, local: latestHashes, remote: merge.files)
        var applied: [String: Data] = [:]
        for (path, sha) in late.files {
            applied[path] = latestHashes[path] == sha ? latest.data[path] : merged[path]
        }
        var next = SyncState(files: merge.files, lastCommit: commit, lastSyncDate: Date())
        for path in late.conflicts {
            applied[path] = latest.data[path] // 冲突时原样保留此刻的本机内容。
            next.files[path] = localHashes[path]
            next.conflicts.append(try space.saveConflict(path: path, local: latest.data[path], remote: merged[path]))
        }
        status = "正在更新本机日记…"
        let changed = try files.apply(files: applied, expected: latestHashes, root: root)
        try space.saveState(next)
        state = next
        conflicts = next.conflicts
        lastSyncDate = next.lastSyncDate
        if changed { store.reloadFromSync() }
        if !conflicts.isEmpty { status = "有 \(conflicts.count) 个冲突需要处理" }
        else if applied.mapValues(SyncHash.blob) != merge.files { status = "等待同步新修改"; pendingSync = true }
        else { status = "已同步" }
    }

    private func remoteData(path: String, remote: GitHubRemoteSnapshot, repo: GitHubRepository,
                            space: SyncFileStore, token: String) async throws -> Data? {
        guard let sha = remote.files[path] else { return nil }
        if let cached = space.readBlob(sha) { return cached }
        status = "正在下载日记与图片…"
        let data = try await api.blob(sha: sha, repository: repo, token: token)
        guard data.count <= SyncFileStore.maximumFileSize else { throw DiarySyncError.oversizedFile(path) }
        try space.saveBlob(data, sha: sha)
        return data
    }

    private func report(_ error: Error) {
        if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(error.code) {
            status = "等待联网"
            errorMessage = "日记已保存在本机，联网后会自动重试"
        } else {
            status = "同步已暂停"
            errorMessage = error.localizedDescription
            if case GitHubError.response(401) = error { requiresLogin = true }
            if case GitHubError.authorization = error { requiresLogin = true }
        }
    }

    private func saveCredential(accessToken: String, refreshToken: String?, expiresAt: Date?) throws {
        let credential = GitHubSessionCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
        let data = try JSONEncoder().encode(credential)
        try credentials.save(String(decoding: data, as: UTF8.self))
        token = accessToken
        self.refreshToken = refreshToken
        tokenExpiresAt = expiresAt
    }

    private func freshToken() async throws -> String {
        guard let token else { throw GitHubError.response(401) }
        guard let expiresAt = tokenExpiresAt, expiresAt <= Date().addingTimeInterval(60) else { return token }
        guard let refreshToken else { throw GitHubError.response(401) }
        let response = try await loginClient.refreshToken(refreshToken)
        guard let accessToken = response.access_token, let newRefresh = response.refresh_token else {
            throw GitHubError.authorization(response.error ?? "bad_refresh_token")
        }
        try saveCredential(accessToken: accessToken, refreshToken: newRefresh,
                           expiresAt: response.expires_in.map { Date().addingTimeInterval(Double($0)) })
        return accessToken
    }
}
