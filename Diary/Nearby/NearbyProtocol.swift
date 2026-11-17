import CryptoKit
import Darwin
import Foundation
import Network

struct NearbyConflictPause: Error {}

func nearbyIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let worker = Task.detached { try Task.checkCancellation(); return try operation() }
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
}

enum NearbyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum NearbyCrypto {
    static let label = "DiaryNearby-v1"
    static func shared(_ privateKey: P256.KeyAgreement.PrivateKey, peer: Data, salt: Data) throws -> SymmetricKey {
        guard peer.count == 65, salt.count == 32 else { throw NearbyError.message("附近同步配对信息无效") }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8), outputByteCount: 32)
    }
    static func derive(_ key: SymmetricKey, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(repeating: 0, count: 32), info: Data(info.utf8), outputByteCount: 32)
    }
    static func code(_ key: SymmetricKey) -> String {
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) } + Data("compare".utf8))
        let number = digest.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return String(format: "%06llu", number % 1_000_000)
    }
    static func seal(_ data: Data, key: SymmetricKey, context: String, nonce: Data? = nil) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, nonce: nonce.map { try AES.GCM.Nonce(data: $0) }, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw NearbyError.message("附近同步加密失败") }
        return combined
    }
    static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
    }
}

final class NearbySocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Diary.NearbyTCP")
    init(host: String, port: Int, interfaceName: String? = nil) throws {
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw NearbyError.message("附近同步端口无效") }
        let parameters = NWParameters.tcp
        if let interfaceName {
            // A required Wi-Fi interface keeps the direct session out of the default VPN path.
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            let ready = DispatchSemaphore(value: 0)
            var interface: NWInterface?
            monitor.pathUpdateHandler = { path in interface = path.availableInterfaces.first { $0.name == interfaceName }; ready.signal() }
            monitor.start(queue: queue)
            _ = ready.wait(timeout: .now() + 3); monitor.cancel()
            guard let interface else { throw NearbyError.message("临时 Wi-Fi 尚未就绪，请重新同步。") }
            parameters.requiredInterface = interface
        }
        let scoped = host.contains(":") && interfaceName != nil ? host + "%" + interfaceName! : host
        connection = NWConnection(host: NWEndpoint.Host(scoped), port: endpointPort, using: parameters)
        let ready = DispatchSemaphore(value: 0), lock = NSLock()
        var completed = false, failure: Error?
        connection.stateUpdateHandler = { [weak connection] state in
            lock.lock(); defer { lock.unlock() }
            guard !completed else { return }
            switch state {
            case .ready: completed = true; ready.signal()
            case .failed(let error): failure = Self.networkError(error, path: connection?.currentPath); completed = true; ready.signal()
            case .waiting(let error):
                if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    failure = Self.networkError(error, path: connection?.currentPath); completed = true; ready.signal()
                }
            case .cancelled: failure = CancellationError(); completed = true; ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        do {
            var signaled = false
            for _ in 0..<60 {
                try Task.checkCancellation()
                if ready.wait(timeout: .now() + 0.25) == .success { signaled = true; break }
            }
            guard signaled else { throw NearbyError.message("连接安卓超时，请确认两端配对后重新同步。") }
            lock.lock(); let error = failure; lock.unlock()
            if let error { throw error }
        } catch { connection.cancel(); throw error }
    }
    private static func networkError(_ error: NWError, path: NWPath?) -> Error {
        if path?.unsatisfiedReason == .localNetworkDenied { return NearbyError.message("请在系统设置的隐私与安全性中允许日记访问本地网络。") }
        return NearbyError.message("临时 Wi-Fi 连接失败：" + error.localizedDescription)
    }
    deinit { connection.cancel() }
    func close() { connection.cancel() }
    func read(_ length: Int) throws -> Data {
        guard length >= 0, length <= NearbyWire.maximumFrame else { throw NearbyError.message("附近同步消息过大") }
        var result = Data()
        while result.count < length {
            try Task.checkCancellation()
            let ready = DispatchSemaphore(value: 0)
            var bytes: Data?, failure: Error?
            connection.receive(minimumIncompleteLength: 1, maximumLength: length - result.count) { data, _, _, error in
                bytes = data; failure = error; ready.signal()
            }
            guard ready.wait(timeout: .now() + 30) == .success else { close(); throw NearbyError.message("附近同步接收超时，请重试。") }
            if let failure { throw failure }
            guard let bytes, !bytes.isEmpty else { throw NearbyError.message("附近同步连接已断开，请重试。") }
            result.append(bytes)
        }
        return result
    }
    func write(_ data: Data) throws {
        try Task.checkCancellation()
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.send(content: data, completion: .contentProcessed { error in failure = error; ready.signal() })
        guard ready.wait(timeout: .now() + 30) == .success else { close(); throw NearbyError.message("附近同步发送超时，请重试。") }
        if let failure { throw failure }
    }
}

final class NearbyWire: @unchecked Sendable {
    static let maximumFrame = 1024 * 1024
    static let chunk = 192 * 1024
    private let socket: NearbySocket
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sending: UInt64 = 0
    private var receiving: UInt64 = 0
    init(socket: NearbySocket, key: SymmetricKey) {
        self.socket = socket
        sendKey = NearbyCrypto.derive(key, info: NearbyCrypto.label + ":mac")
        receiveKey = NearbyCrypto.derive(key, info: NearbyCrypto.label + ":android")
    }
    private func nonce(_ sequence: UInt64) -> Data { var n = sequence.bigEndian; return Data(repeating: 0, count: 4) + withUnsafeBytes(of: &n) { Data($0) } }
    func request(_ type: String, _ values: [String: Any] = [:]) throws -> [String: Any] {
        var message = values; message["type"] = type
        let plain = try JSONSerialization.data(withJSONObject: message)
        let box = try NearbyCrypto.seal(plain, key: sendKey, context: "mac", nonce: nonce(sending))
        sending += 1
        guard box.count <= Self.maximumFrame else { throw NearbyError.message("附近同步消息过大") }
        var length = UInt32(box.count).bigEndian
        try socket.write(withUnsafeBytes(of: &length) { Data($0) } + box)
        let count = try socket.read(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (28...Self.maximumFrame).contains(Int(count)) else { throw NearbyError.message("附近同步消息无效") }
        let response = try socket.read(Int(count))
        guard response.prefix(12) == nonce(receiving) else { throw NearbyError.message("附近同步消息顺序异常") }
        receiving += 1
        let data = try NearbyCrypto.open(response, key: receiveKey, context: "android")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = json["type"] as? String else { throw NearbyError.message("附近同步协议不兼容") }
        if kind == "error" { throw NearbyError.message(json["message"] as? String ?? "附近同步失败") }
        return json
    }
    func close() { socket.close() }
}

struct NearbyConflict: Codable, Identifiable {
    var id: String { path }
    let path: String
    let localSHA: String?
    let remoteSHA: String?
}
struct NearbyState: Codable {
    var schema = 1
    var base: [String: String] = [:]
    var pending: [String: String]?
    var conflicts: [NearbyConflict] = []
    var resolutions: [String: SyncResolution] = [:]
    var lastSyncDate: String?
}
struct NearbySpace {
    let directory: URL
    var files: SyncFileStore { SyncFileStore(directory: directory) }
    func load() throws -> NearbyState {
        let file = directory.appendingPathComponent("nearby-state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return NearbyState() }
        let state = try JSONDecoder().decode(NearbyState.self, from: Data(contentsOf: file))
        guard state.schema == 1, validHashes(state.base), validHashes(state.pending ?? [:]),
              state.conflicts.allSatisfy({ SyncPath.isAllowed($0.path) && ($0.localSHA.map(validHash) ?? true) && ($0.remoteSHA.map(validHash) ?? true) }),
              state.resolutions.allSatisfy({ SyncPath.isAllowed($0.key) }) else { throw NearbyError.message("附近同步记录无法读取") }
        return state
    }
    func save(_ state: NearbyState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("nearby-state.json"), options: .atomic)
    }
    func prune(_ state: NearbyState) {
        let keep = Set(state.conflicts.flatMap { [$0.localSHA, $0.remoteSHA].compactMap { $0 } } + Array((state.pending ?? [:]).values))
        let objects = directory.appendingPathComponent("objects", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil)) ?? []
            where validHash(file.lastPathComponent) && !keep.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }
    static func make(peer: String, root: URL) -> NearbySpace {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return NearbySpace(directory: support.appendingPathComponent("Diary/NearbySync/" + SyncHash.key(root.resolvingSymlinksInPath().path + ":" + peer), isDirectory: true))
    }
}
func validHash(_ value: String) -> Bool { value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) } }
func validHashes(_ values: [String: String]) -> Bool { values.count <= 20_000 && values.allSatisfy { SyncPath.isAllowed($0.key) && validHash($0.value) } }
func nearbyBase(mac: NearbyState, android: NearbyState) -> [String: String] {
    if mac.base == android.base || mac.pending == android.base { return mac.base }
    if android.pending == mac.base { return android.base }
    return [:]
}

struct NearbyPrepared: @unchecked Sendable {
    let files: [String: Data]
    let hashes: [String: String]
    let conflicts: [NearbyConflict]
    let state: NearbyState
}
enum NearbyTransfer {
    private static func expectOK(_ response: [String: Any]) throws {
        guard response["type"] as? String == "ok" else { throw NearbyError.message("附近同步协议响应无效") }
    }
    static func prepare(wire: NearbyWire, local: SyncLocalSnapshot, space: NearbySpace, peerId: String) throws -> NearbyPrepared {
        let response = try wire.request("hello", ["peerId": peerId])
        guard response["type"] as? String == "snapshot", let remote = response["files"] as? [String: String], validHashes(remote),
              let androidJSON = response["state"] else { throw NearbyError.message("安卓同步文件列表无效") }
        let android = try JSONDecoder().decode(NearbyState.self, from: JSONSerialization.data(withJSONObject: androidJSON))
        guard android.schema == 1, validHashes(android.base), validHashes(android.pending ?? [:]) else { throw NearbyError.message("安卓同步记录无效") }
        var state = try space.load()
        var resolutions = state.resolutions
        for (path, choice) in android.resolutions {
            if let other = resolutions[path], other.choice != choice.choice { resolutions.removeValue(forKey: path) }
            else { resolutions[path] = choice }
        }
        let merge = SyncMerge.plan(base: nearbyBase(mac: state, android: android), local: local.hashes, remote: remote, resolutions: resolutions)
        func download(_ path: String) throws -> Data? {
            guard let sha = remote[path] else { return nil }
            if let cached = space.files.readBlob(sha) { return cached }
            var bytes = Data(); var total: Int?
            repeat {
                let part = try wire.request("get", ["path": path, "offset": bytes.count])
                guard part["type"] as? String == "blob", part["sha"] as? String == sha, part["offset"] as? Int == bytes.count,
                      let size = part["size"] as? Int, (0...SyncFileStore.maximumFileSize).contains(size),
                      total == nil || total == size, let value = part["data"] as? String, let data = Data(base64Encoded: value),
                      data.count <= NearbyWire.chunk, bytes.count + data.count <= size,
                      !data.isEmpty || size == 0 else { throw NearbyError.message("安卓文件分块无效") }
                total = size; bytes.append(data)
            } while bytes.count < total!
            guard SyncHash.blob(bytes) == sha else { throw NearbyError.message("安卓文件校验失败") }
            try space.files.saveBlob(bytes, sha: sha)
            return bytes
        }
        func upload(_ path: String, _ bytes: Data) throws {
            try expectOK(wire.request("put-start", ["path": path, "sha": SyncHash.blob(bytes), "size": bytes.count]))
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + NearbyWire.chunk)
                try expectOK(wire.request("put-chunk", ["offset": offset, "data": bytes.subdata(in: offset..<end).base64EncodedString()]))
                offset = end
            }
            try expectOK(wire.request("put-end"))
        }
        if !merge.conflicts.isEmpty {
            let conflicts = try merge.conflicts.map { path -> NearbyConflict in
                if let bytes = local.data[path] { try upload(path, bytes); try space.files.saveBlob(bytes, sha: SyncHash.blob(bytes)) }
                _ = try download(path)
                return NearbyConflict(path: path, localSHA: local.hashes[path], remoteSHA: remote[path])
            }
            state.conflicts = conflicts; state.resolutions = resolutions
            try space.save(state)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conflicts))
            try expectOK(wire.request("conflicts", ["items": json]))
            return NearbyPrepared(files: [:], hashes: [:], conflicts: conflicts, state: state)
        }
        var merged: [String: Data] = [:]
        for path in merge.files.keys.sorted() {
            if local.hashes[path] == merge.files[path] { merged[path] = local.data[path] }
            else { merged[path] = try download(path) }
            guard let data = merged[path], SyncHash.blob(data) == merge.files[path] else { throw NearbyError.message("同步文件不完整") }
        }
        guard merged.values.reduce(0, { $0 + $1.count }) <= 512 * 1024 * 1024 else { throw NearbyError.message("日记与图片超过本次附近同步的 512MiB 上限") }
        try space.files.validate(merged)
        for (path, bytes) in merged where remote[path] != SyncHash.blob(bytes) { try upload(path, bytes) }
        let ready = try wire.request("prepare", ["files": merge.files])
        guard ready["type"] as? String == "ready" else { throw NearbyError.message("安卓尚未准备好同步") }
        state.pending = merge.files; try space.save(state)
        return NearbyPrepared(files: merged, hashes: merge.files, conflicts: [], state: state)
    }
}

// Association can finish before DHCP. Wait for an IPv4 route on the direct interface.
func nearbyIPv4Ready(interface: String, host: String) -> Bool {
    var target = in_addr()
    guard host.withCString({ inet_pton(AF_INET, $0, &target) }) == 1 else { return false }
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return false }
    defer { freeifaddrs(list) }
    var item = list
    while let current = item {
        defer { item = current.pointee.ifa_next }
        guard String(cString: current.pointee.ifa_name) == interface,
              let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              let mask = current.pointee.ifa_netmask else { continue }
        let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
        let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
        if netmask != 0 && ip != target.s_addr && (ip & netmask) == (target.s_addr & netmask) { return true }
    }
    return false
}
