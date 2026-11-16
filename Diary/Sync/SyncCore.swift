import CryptoKit
import Foundation

enum SyncHash {
    static func blob(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func key(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncPath {
    static func isAllowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.first == "entries"
            && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains("\0") }
    }
}

enum SyncChoice: String, Codable { case local, remote }

struct SyncResolution: Codable {
    let localSHA: String?
    let remoteSHA: String?
    let choice: SyncChoice
}

struct SyncMerge {
    let files: [String: String]
    let conflicts: [String]

    static func plan(base: [String: String], local: [String: String], remote: [String: String],
                     resolutions: [String: SyncResolution] = [:]) -> SyncMerge {
        var merged: [String: String] = [:]
        var conflicts: [String] = []
        for path in Set(base.keys).union(local.keys).union(remote.keys).sorted() {
            let before = base[path], here = local[path], there = remote[path]
            let chosen: String?
            if here == there { chosen = here }
            else if here == before { chosen = there }
            else if there == before { chosen = here }
            else if let resolution = resolutions[path], resolution.localSHA == here, resolution.remoteSHA == there {
                chosen = resolution.choice == .local ? here : there
            } else {
                conflicts.append(path)
                continue
            }
            merged[path] = chosen
        }
        return SyncMerge(files: merged, conflicts: conflicts)
    }
}

struct SyncConflict: Codable, Identifiable {
    let id: String
    let path: String
    let localSHA: String?
    let remoteSHA: String?
}

struct SyncState: Codable {
    var schema = 1
    var files: [String: String] = [:]
    var lastCommit: String?
    var lastSyncDate: Date?
    var conflicts: [SyncConflict] = []
    var resolutions: [String: SyncResolution] = [:]
}

enum DiarySyncError: LocalizedError {
    case unsafePath(String)
    case oversizedFile(String)
    case localChanged
    case rootChanged
    case duplicateEntry(String)
    case invalidState
    case invalidEntry(String)
    case unlockLegacyEncryption
    case diskSwap(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "同步遇到不安全的文件路径：\(path)"
        case .oversizedFile(let path): return "文件超过 GitHub 支持的大小，请缩小图片后重试：\(path)"
        case .localChanged: return "日记在同步期间发生变化，会继续同步最新内容"
        case .rootChanged: return "日记存放位置已更改，请重新选择同步仓库"
        case .duplicateEntry(let id): return "两份不同路径的日记使用相同编号（\(id)），请在访达中整理后重试"
        case .invalidState: return "本机同步记录无法读取，已暂停同步以保护日记"
        case .invalidEntry(let path): return "日记文件格式或加密参数不完整，已暂停同步：\(path)"
        case .unlockLegacyEncryption: return "请先在搜索框解锁一次隐私日记，准备旧版加密文件后即可继续同步"
        case .diskSwap: return "无法更新本机日记，原文件已保留，请检查存放目录权限"
        }
    }
}
