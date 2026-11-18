import CoreBluetooth
import CoreLocation
import CoreWLAN
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class NearbyManager: NSObject, @preconcurrency CBPeripheralManagerDelegate, @preconcurrency CLLocationManagerDelegate {
    private(set) var isWaiting = false
    private(set) var isBusy = false
    private(set) var status = "无需互联网或同一个路由器，可与附近安卓直接同步。"
    private(set) var pairingCode: String?
    private(set) var conflicts: [NearbyConflict] = []
    private(set) var lastSyncDate: String?
    var backgroundEnabled = UserDefaults.standard.bool(forKey: "NearbyBackground") {
        didSet {
            UserDefaults.standard.set(backgroundEnabled, forKey: "NearbyBackground")
            if backgroundEnabled, let store { start(store: store) }
            else if !backgroundEnabled { stop() }
        }
    }
    private(set) var trustedDevices: [NearbyTrustedDevice] = (UserDefaults.standard.data(forKey: "NearbyTrustedDevices").flatMap { try? JSONDecoder().decode([NearbyTrustedDevice].self, from: $0) }) ?? []
    @ObservationIgnored private var signing: NearbySigningIdentity?
    @ObservationIgnored private var identityTask: Task<Void, Never>?
    @ObservationIgnored private var allowTrust = false
    func forget(_ id: String) {
        trustedDevices.removeAll { $0.id == id }; saveTrusted()
    }
    private func saveTrusted() { UserDefaults.standard.set(try? JSONEncoder().encode(trustedDevices), forKey: "NearbyTrustedDevices") }
    func resumeBackground(store: DiaryStore) { self.store = store; if backgroundEnabled { start(store: store) } }

    @ObservationIgnored private var peripheral: CBPeripheralManager?
    @ObservationIgnored private var characteristic: CBMutableCharacteristic?
    @ObservationIgnored private var location: CLLocationManager?
    @ObservationIgnored private var privateKey: P256.KeyAgreement.PrivateKey?
    @ObservationIgnored private var salt = Data()
    @ObservationIgnored private var sessionKey: SymmetricKey?
    @ObservationIgnored private var network: [String: Any]?
    @ObservationIgnored private var packet = Data()
    @ObservationIgnored private var packetIndex = 0
    @ObservationIgnored private var packetCount = 0
    @ObservationIgnored private var packetCentral: UUID?
    @ObservationIgnored private var packetStarted = Date()
    @ObservationIgnored private weak var store: DiaryStore?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var wire: NearbyWire?
    @ObservationIgnored private var space: NearbySpace?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var waitingLocation = false
    private let serviceID = CBUUID(string: "42a66486-a391-4f24-83d4-74525b9e5d70")
    private let characteristicID = CBUUID(string: "42a66486-a391-4f24-83d4-74525b9e5d71")
    private var localId: String {
        if let value = UserDefaults.standard.string(forKey: "NearbyDeviceId") { return value }
        let value = UUID().uuidString.lowercased(); UserDefaults.standard.set(value, forKey: "NearbyDeviceId"); return value
    }
    func start(store: DiaryStore) {
        guard !isBusy, !isWaiting else { return }
        self.store = store; generation += 1
        network = nil; sessionKey = nil; pairingCode = nil; packet = Data(); packetCentral = nil
        privateKey = P256.KeyAgreement.PrivateKey()
        salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        if let peer = UserDefaults.standard.string(forKey: "NearbyLastPeer") {
            space = NearbySpace.make(peer: peer, root: store.dataRoot)
            if let state = try? space?.load() { conflicts = state.conflicts.filter { state.resolutions[$0.path] == nil }; lastSyncDate = state.lastSyncDate }
        }
        isWaiting = true; status = "正在准备蓝牙发现…"
        let run = generation
        identityTask = Task {
            do {
                let identity = try await nearbyIO { try NearbySigningIdentity.load() }
                guard isWaiting, generation == run else { return }
                signing = identity
                if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: .main) }
                else if peripheral?.state == .poweredOn { configureService() }
                else { peripheralManagerDidUpdateState(peripheral!) }
            } catch { isWaiting = false; status = error.localizedDescription }
        }
    }
    func stop() {
        peripheral?.stopAdvertising(); peripheral?.removeAllServices()
        identityTask?.cancel(); task?.cancel(); wire?.close()
        isWaiting = false; pairingCode = nil; waitingLocation = false
        if task == nil { isBusy = false; network = nil; sessionKey = nil }
        status = "附近同步已取消。"
    }
    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        guard isWaiting else { return }
        if manager.state == .poweredOn { configureService() }
        else if manager.state == .unauthorized { status = "请在系统设置中允许日记使用蓝牙。"; isWaiting = false }
        else if manager.state == .unsupported { status = "此 Mac 不支持所需蓝牙功能。"; isWaiting = false }
        else if manager.state == .poweredOff { status = "请开启蓝牙后重试。"; isWaiting = false }
    }
    private func configureService() {
        peripheral?.removeAllServices()
        let service = CBMutableService(type: serviceID, primary: true)
        let value = CBMutableCharacteristic(type: characteristicID, properties: [.read, .write], value: nil, permissions: [.readable, .writeable])
        characteristic = value; service.characteristics = [value]; peripheral?.add(service)
    }
    func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard isWaiting else { return }
        if let error { status = error.localizedDescription; isWaiting = false; return }
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID], CBAdvertisementDataLocalNameKey: "日记 Mac"])
    }
    func peripheralManagerDidStartAdvertising(_ manager: CBPeripheralManager, error: Error?) {
        if let error { status = error.localizedDescription; isWaiting = false }
        else { status = "已开启附近发现，请在安卓日记中扫描这台 Mac。" }
    }
    func peripheralManager(_ manager: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard isWaiting, request.characteristic.uuid == characteristicID, let privateKey, let signing else { manager.respond(to: request, withResult: .readNotPermitted); return }
        do {
            let value = try JSONSerialization.data(withJSONObject: ["v": 1, "peerId": localId,
                "publicKey": privateKey.publicKey.x963Representation.base64EncodedString(), "salt": salt.base64EncodedString(),
                "platform": "mac", "name": Host.current().localizedName ?? "Mac", "identity": signing.publicKey,
                "signature": try signing.key.signature(for: NearbyCrypto.identityChallenge(receiver: localId, sender: "",
                    publicKey: privateKey.publicKey.x963Representation.base64EncodedString(), salt: salt.base64EncodedString())).derRepresentation.base64EncodedString()])
            guard request.offset <= value.count else { manager.respond(to: request, withResult: .invalidOffset); return }
            request.value = value.subdata(in: request.offset..<value.count)
            manager.respond(to: request, withResult: .success)
        } catch { manager.respond(to: request, withResult: .unlikelyError) }
    }
    func peripheralManager(_ manager: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            do {
                guard isWaiting, network == nil, request.characteristic.uuid == characteristicID, let value = request.value,
                      value.count >= 5, value.count <= 180, let privateKey else { throw NearbyError.message("附近配对消息无效") }
                let bytes = [UInt8](value)
                let index = Int(bytes[0]) * 256 + Int(bytes[1]), count = Int(bytes[2]) * 256 + Int(bytes[3])
                guard (1...256).contains(count), index < count else { throw NearbyError.message("附近配对分块无效") }
                if index == 0, packetCentral == nil || Date().timeIntervalSince(packetStarted) > 15 {
                    packet = Data(); packetIndex = 0; packetCount = count; packetCentral = request.central.identifier; packetStarted = Date()
                }
                guard request.central.identifier == packetCentral, index == packetIndex, count == packetCount, packet.count + value.count - 4 <= 4096 else { throw NearbyError.message("附近配对消息顺序异常") }
                packet.append(value.dropFirst(4)); packetIndex += 1
                if packetIndex == packetCount {
                    guard packet.count >= 93 else { throw NearbyError.message("附近配对消息不完整") }
                    let key = try NearbyCrypto.shared(privateKey, peer: packet.prefix(65), salt: salt)
                    let plain = try NearbyCrypto.open(packet.dropFirst(65), key: key, context: "network")
                    guard let config = try JSONSerialization.jsonObject(with: plain) as? [String: Any], config["type"] as? String == "network",
                          config["macId"] as? String == localId, let id = config["peerId"] as? String, UUID(uuidString: id) != nil,
                          let ssid = config["ssid"] as? String, ssid.hasPrefix("DIRECT-"), ssid.utf8.count <= 32,
                          let password = config["password"] as? String, (8...63).contains(password.utf8.count),
                          let host = config["host"] as? String, host.count <= 15,
                          let port = config["port"] as? Int, (1...65535).contains(port) else { throw NearbyError.message("安卓临时网络信息无效") }
                    let identity = config["identity"] as? String
                    if let identity {
                        guard let signature = config["signature"] as? String,
                              NearbyCrypto.verify(identity: identity, signature: signature,
                                data: NearbyCrypto.identityChallenge(receiver: localId, sender: id,
                                    publicKey: privateKey.publicKey.x963Representation.base64EncodedString(), salt: salt.base64EncodedString(), senderKey: packet.prefix(65).base64EncodedString())) else {
                            throw NearbyError.message("设备身份签名无效，请重新配对")
                        }
                    }
                    let trusted = identity != nil && trustedDevices.contains { $0.id == id && $0.identity == identity }
                    if config["automatic"] as? Bool == true && (!backgroundEnabled || !trusted) { throw NearbyError.message("没有授权此设备自动同步") }
                    allowTrust = trusted
                    network = config; sessionKey = key; pairingCode = trusted ? nil : NearbyCrypto.pairCode(key, first: identity, second: identity == nil ? nil : signing?.publicKey)
                    isWaiting = false; isBusy = true; manager.stopAdvertising()
                    status = "请核对两端配对码，确认是你的安卓设备。"
                    packet = Data(); packetCentral = nil
                    if trusted { Task { self.confirm(remember: true) } }
                }
                manager.respond(to: request, withResult: .success)
            } catch {
                packet = Data(); packetCentral = nil
                manager.respond(to: request, withResult: .unlikelyError)
                status = error.localizedDescription
            }
        }
    }
    func confirm(remember: Bool = false) {
        allowTrust = remember
        guard network != nil, sessionKey != nil else { return }
        pairingCode = nil
        if location == nil { location = CLLocationManager(); location?.delegate = self }
        switch location!.authorizationStatus {
        case .notDetermined:
            waitingLocation = true; status = "请允许定位权限，以便 macOS 查找并接入安卓临时 Wi-Fi。"
            location?.requestWhenInUseAuthorization()
        case .authorizedAlways: beginTransfer()
        default: stop(); status = "macOS 需要定位权限才能扫描临时 Wi-Fi，请在系统设置中允许后重试。"
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waitingLocation else { return }
        if manager.authorizationStatus == .authorizedAlways { waitingLocation = false; beginTransfer() }
        else if manager.authorizationStatus != .notDetermined { stop(); status = "没有定位权限，无法接入安卓临时网络。" }
    }
    private func beginTransfer() {
        guard task == nil, let config = network, let key = sessionKey, let store else { return }
        let run = generation
        let root = store.dataRoot
        let peer = config["peerId"] as! String
        let ssid = config["ssid"] as! String
        let password = config["password"] as! String
        let host = config["host"] as! String
        let host6 = config["host6"] as? String
        let port = config["port"] as! Int
        let space = NearbySpace.make(peer: peer, root: root)
        self.space = space
        UserDefaults.standard.set(peer, forKey: "NearbyLastPeer")
        status = "正在接入安卓临时直连网络…"
        task = Task { [weak self, weak store] in
            guard let self, let store else { return }
            do {
                let interfaceName = try await nearbyIO { try Self.joinNetwork(ssid: ssid, password: password, host: host) }
                try Task.checkCancellation()
                guard store.dataRoot == root else { throw DiarySyncError.rootChanged }
                store.flushEditorsForSync(); try store.prepareForSync()
                let local = try await nearbyIO { try space.files.scan(root: root) }
                let socket = try await nearbyIO {
                    if let host6, host6.lowercased().hasPrefix("fe80:"), host6.count <= 39 {
                        do { return try NearbySocket(host: host6, port: port, interfaceName: interfaceName) }
                        catch { try Task.checkCancellation() }
                    }
                    return try NearbySocket(host: host, port: port, interfaceName: interfaceName)
                }
                let wire = NearbyWire(socket: socket, key: key); self.wire = wire
                try Task.checkCancellation()
                status = "正在核对日记与图片变更…"
                let ownId = localId
                let ownIdentity = signing?.publicKey
                let peerIdentity = config["identity"] as? String
                let trustConsent = allowTrust
                let prepared = try await nearbyIO { try NearbyTransfer.prepare(wire: wire, local: local, space: space, peerId: ownId, identity: ownIdentity, expectedIdentity: peerIdentity, allowTrust: trustConsent) }
                try Task.checkCancellation()
                if !prepared.conflicts.isEmpty {
                    conflicts = prepared.conflicts; status = "有 \(conflicts.count) 个冲突，请选择保留版本后重新同步。"
                    throw NearbyConflictPause()
                }
                guard store.dataRoot == root else { throw DiarySyncError.rootChanged }
                store.flushEditorsForSync()
                guard try space.files.scan(root: root).hashes == local.hashes else { throw DiarySyncError.localChanged }
                let committed = try await nearbyIO { try wire.request("commit") }
                guard committed["type"] as? String == "committed" else { throw NearbyError.message("安卓未完成保存") }
                try Task.checkCancellation()
                guard store.dataRoot == root else { throw DiarySyncError.rootChanged }
                store.flushEditorsForSync()
                _ = try space.files.apply(files: prepared.files, expected: local.hashes, root: root)
                var next = NearbyState(); next.base = prepared.hashes; next.lastSyncDate = ISO8601DateFormatter().string(from: Date())
                try space.save(next)
                store.reloadFromSync(); store.onDiskChange?()
                _ = try await nearbyIO { try wire.request("done") }
                space.prune(next)
                if trustConsent, prepared.peerTrust, let peerIdentity {
                    trustedDevices.removeAll { $0.id == peer }
                    trustedDevices.append(NearbyTrustedDevice(id: peer, name: String((config["name"] as? String ?? "安卓").prefix(80)), identity: peerIdentity))
                    saveTrusted()
                }
                conflicts = []; lastSyncDate = next.lastSyncDate; status = "已完成附近同步。"
            } catch is NearbyConflictPause { /* Conflict choices are shown above. */ }
            catch is CancellationError { status = "附近同步已取消。" }
            catch { status = Task.isCancelled ? "附近同步已取消。" : error.localizedDescription }
            wire?.close(); wire = nil
            // Keep the session busy until the old direct network is released.
            await Task.detached { Self.releaseNetwork(ssid) }.value
            task = nil
            if generation == run { isBusy = false; network = nil; sessionKey = nil }
            if backgroundEnabled && generation == run {
                try? await Task.sleep(for: .seconds(2))
                if backgroundEnabled { start(store: store) }
            }
        }
    }
    nonisolated private static func joinNetwork(ssid: String, password: String, host: String) throws -> String {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { throw NearbyError.message("请先开启 Mac 的 Wi-Fi。") }
        for _ in 0..<25 {
            try Task.checkCancellation()
            if let network = try interface.scanForNetworks(withSSID: Data(ssid.utf8)).first {
                try Task.checkCancellation()
                try interface.associate(to: network, password: password)
                guard let name = interface.interfaceName else { throw NearbyError.message("无法确定临时 Wi-Fi 接口") }
                for _ in 0..<120 {
                    try Task.checkCancellation()
                    if interface.ssid() == ssid && nearbyIPv4Ready(interface: name, host: host) { return name }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                throw NearbyError.message("临时 Wi-Fi 未取得地址，请重新同步。")
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw NearbyError.message("未找到安卓临时网络，请靠近设备后重试。")
    }
    nonisolated private static func releaseNetwork(_ ssid: String) {
        if let interface = CWWiFiClient.shared().interface(), interface.ssid() == ssid { interface.disassociate() }
    }
    func resolve(_ conflict: NearbyConflict, choice: SyncChoice) {
        guard !isBusy, let space else { return }
        do {
            var state = try space.load()
            state.resolutions[conflict.path] = SyncResolution(localSHA: conflict.localSHA, remoteSHA: conflict.remoteSHA, choice: choice)
            try space.save(state); conflicts = state.conflicts.filter { state.resolutions[$0.path] == nil }
            status = "已选择版本，请重新开启附近同步。"
        } catch { status = error.localizedDescription }
    }
}
