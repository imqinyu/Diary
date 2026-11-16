import Foundation

struct GitHubAccount: Codable, Equatable, Sendable {
    let login: String
}

struct GitHubRepository: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let full_name: String
    let `private`: Bool
    let default_branch: String
    let permissions: Permissions?
    struct Permissions: Codable, Equatable, Sendable { let push: Bool? }
    var owner: String { String(full_name.split(separator: "/").first ?? "") }
    var canSync: Bool { `private` && permissions?.push == true }
}

struct GitHubRemoteSnapshot: Sendable {
    let commit: String?
    let tree: String?
    let files: [String: String]
}

struct GitHubDeviceCode: Codable, Sendable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int
}

struct GitHubTokenResponse: Decodable, Sendable {
    let access_token: String?
    let error: String?
    let interval: Int?
    let refresh_token: String?
    let expires_in: Int?
}

enum GitHubError: LocalizedError {
    case response(Int)
    case authorization(String)
    case unsafeRepository
    case branchChanged
    case invalidData
    case truncatedTree

    var errorDescription: String? {
        switch self {
        case .response(401): return "GitHub 授权已过期，请重新登录"
        case .response(403): return "GitHub 拒绝访问，请检查仓库权限或稍后重试"
        case .response(404): return "找不到 GitHub 仓库，或账号没有访问权限"
        case .response(let code): return "GitHub 请求失败（\(code)），请稍后重试"
        case .authorization(let code):
            switch code {
            case "access_denied": return "你已取消 GitHub 授权"
            case "expired_token": return "登录验证码已过期，请重新登录"
            case "device_flow_disabled": return "这个 OAuth 应用尚未开启 Device Flow"
            default: return "GitHub 登录失败，请重新登录"
            }
        case .unsafeRepository: return "请选择有写入权限的私有仓库，软件不会向公开仓库上传日记"
        case .branchChanged: return "远端在同步期间发生变化，正在重新检查"
        case .invalidData: return "GitHub 返回的数据不完整，同步已停止"
        case .truncatedTree: return "仓库文件太多，GitHub 未返回完整目录，同步已停止以保护日记"
        }
    }
}

protocol GitHubSyncAPI: Sendable {
    func account(token: String) async throws -> GitHubAccount
    func repositories(token: String) async throws -> [GitHubRepository]
    func repository(owner: String, name: String, token: String) async throws -> GitHubRepository
    func createRepository(name: String, token: String) async throws -> GitHubRepository
    func snapshot(repository: GitHubRepository, token: String) async throws -> GitHubRemoteSnapshot
    func blob(sha: String, repository: GitHubRepository, token: String) async throws -> Data
    func publish(files: [String: Data?], parent: GitHubRemoteSnapshot, repository: GitHubRepository, token: String) async throws -> String
}

/// 直接使用 Git 数据库 API；不依赖用户机器上的 Git，也不强推分支。
struct GitHubClient: GitHubSyncAPI {
    static let clientID = "Ov23li7XFxnPesSAN1jj"
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    private func request<T: Decodable>(_ path: String, token: String?, method: String = "GET",
                                       body: [String: Any]? = nil, login: Bool = false) async throws -> T {
        let host = login ? "https://github.com" : "https://api.github.com"
        guard let url = URL(string: host + path) else { throw GitHubError.invalidData }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Diary/1.0", forHTTPHeaderField: "User-Agent")
        if !login { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidData }
        guard (200..<300).contains(response.statusCode) else { throw GitHubError.response(response.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func beginLogin() async throws -> GitHubDeviceCode {
        try await request("/login/device/code", token: nil, method: "POST",
                          body: ["client_id": Self.clientID, "scope": "repo"], login: true)
    }

    func pollLogin(code: GitHubDeviceCode) async throws -> GitHubTokenResponse {
        try await request("/login/oauth/access_token", token: nil, method: "POST", body: [
            "client_id": Self.clientID, "device_code": code.device_code,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ], login: true)
    }

    func refreshToken(_ token: String) async throws -> GitHubTokenResponse {
        try await request("/login/oauth/access_token", token: nil, method: "POST", body: [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": token
        ], login: true)
    }

    func account(token: String) async throws -> GitHubAccount {
        try await request("/user", token: token)
    }

    func repositories(token: String) async throws -> [GitHubRepository] {
        var all: [GitHubRepository] = []
        for page in 1...100 {
            let batch: [GitHubRepository] = try await request("/user/repos?visibility=private&sort=updated&per_page=100&page=\(page)", token: token)
            all.append(contentsOf: batch.filter(\.canSync))
            if batch.count < 100 { return all }
        }
        throw GitHubError.truncatedTree
    }

    func repository(owner: String, name: String, token: String) async throws -> GitHubRepository {
        let value: GitHubRepository = try await request("/repos/\(component(owner))/\(component(name))", token: token)
        guard value.canSync else { throw GitHubError.unsafeRepository }
        return value
    }

    func createRepository(name: String, token: String) async throws -> GitHubRepository {
        let value: GitHubRepository = try await request("/user/repos", token: token, method: "POST",
            body: ["name": name, "private": true, "auto_init": true, "description": "Private diary sync"])
        // 创建接口可能省略 permissions；重新读取验证私有状态和写权限。
        return try await repository(owner: value.owner, name: value.name, token: token)
    }

    func snapshot(repository: GitHubRepository, token: String) async throws -> GitHubRemoteSnapshot {
        struct Ref: Decodable { struct Object: Decodable { let sha: String }; let object: Object }
        struct Commit: Decodable { struct Tree: Decodable { let sha: String }; let tree: Tree }
        struct Tree: Decodable {
            struct Item: Decodable { let path: String; let type: String; let mode: String; let sha: String }
            let tree: [Item]
            let truncated: Bool
        }
        let base = repoPath(repository)
        let ref: Ref
        do {
            ref = try await request(base + "/git/ref/heads/" + component(repository.default_branch), token: token)
        } catch GitHubError.response(let status) where status == 404 || status == 409 {
            // 只把真正的空仓库视为空分支，不能把删掉的分支当作空仓库覆盖。
            let branches: [RefBranch] = try await request(base + "/branches?per_page=1", token: token)
            guard branches.isEmpty else { throw GitHubError.branchChanged }
            return GitHubRemoteSnapshot(commit: nil, tree: nil, files: [:])
        }
        let commit: Commit = try await request(base + "/git/commits/" + ref.object.sha, token: token)
        let tree: Tree = try await request(base + "/git/trees/" + commit.tree.sha + "?recursive=1", token: token)
        guard !tree.truncated else { throw GitHubError.truncatedTree }
        var files: [String: String] = [:]
        for item in tree.tree where item.path == "entries" || item.path.hasPrefix("entries/") {
            if item.type == "tree" { continue }
            guard item.type == "blob", item.mode == "100644" || item.mode == "100755", SyncPath.isAllowed(item.path) else {
                throw GitHubError.invalidData
            }
            files[item.path] = item.sha
        }
        return GitHubRemoteSnapshot(commit: ref.object.sha, tree: commit.tree.sha, files: files)
    }

    private struct RefBranch: Decodable { let name: String }

    func blob(sha: String, repository: GitHubRepository, token: String) async throws -> Data {
        struct Blob: Decodable { let content: String; let encoding: String }
        let blob: Blob = try await request(repoPath(repository) + "/git/blobs/" + component(sha), token: token)
        guard blob.encoding == "base64", let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters),
              SyncHash.blob(data) == sha else { throw GitHubError.invalidData }
        return data
    }

    func publish(files: [String: Data?], parent: GitHubRemoteSnapshot, repository: GitHubRepository, token: String) async throws -> String {
        // 提交前再次检查可见性，仓库变成公开时立即停止。
        _ = try await self.repository(owner: repository.owner, name: repository.name, token: token)
        let base = repoPath(repository)
        struct SHA: Decodable { let sha: String }
        if parent.commit == nil {
            // GitHub 的 Git 数据库 API 无法在没有分支的仓库创建第一个 ref。
            // 只创建一个固定说明文件，再重新拉取并合并，绝不覆盖已有分支。
            struct Initial: Decodable { struct Commit: Decodable { let sha: String }; let commit: Commit }
            do {
                let _: Initial = try await request(base + "/contents/README.md", token: token, method: "PUT", body: [
                    "message": "Initialize private diary repository", "branch": repository.default_branch,
                    "content": Data("# Private diary\n".utf8).base64EncodedString()
                ])
            } catch GitHubError.response(let code) where code == 409 || code == 422 {
                throw GitHubError.branchChanged
            }
            throw GitHubError.branchChanged
        }
        var items: [[String: Any]] = []
        for path in files.keys.sorted() {
            guard SyncPath.isAllowed(path) else { throw GitHubError.invalidData }
            if let data = files[path] ?? nil {
                let blob: SHA = try await request(base + "/git/blobs", token: token, method: "POST",
                    body: ["encoding": "base64", "content": data.base64EncodedString()])
                guard blob.sha == SyncHash.blob(data) else { throw GitHubError.invalidData }
                items.append(["path": path, "mode": "100644", "type": "blob", "sha": blob.sha])
            } else {
                items.append(["path": path, "mode": "100644", "type": "blob", "sha": NSNull()])
            }
        }
        let tree: SHA = try await request(base + "/git/trees", token: token, method: "POST",
                                         body: ["base_tree": parent.tree!, "tree": items])
        let commit: SHA = try await request(base + "/git/commits", token: token, method: "POST", body: [
            "message": "Sync diary", "tree": tree.sha, "parents": [parent.commit!]
        ])
        _ = try await self.repository(owner: repository.owner, name: repository.name, token: token)
        struct UpdatedRef: Decodable { let ref: String }
        do {
            let _: UpdatedRef = try await request(base + "/git/refs/heads/" + component(repository.default_branch),
                token: token, method: "PATCH", body: ["sha": commit.sha, "force": false])
        } catch GitHubError.response(let code) where code == 409 || code == 422 {
            throw GitHubError.branchChanged
        }
        return commit.sha
    }

    private func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    private func repoPath(_ repository: GitHubRepository) -> String {
        "/repos/\(component(repository.owner))/\(component(repository.name))"
    }
}
