import CryptoKit
import Foundation

@main
struct NearbyChecks {
    static let peer = "11111111-1111-4111-8111-111111111111"
    static let keyBytes = Data((0..<32).map(UInt8.init))
    static let a = "entries/2026/11/17/2026-11-17-1.md"
    static let b = "entries/2026/11/17/2026-11-17-2.md"
    static let c = "entries/2026/11/17/2026-11-17-3.md"
    static let image = "entries/2026/11/17/assets/2026-11-17-2/mac.png"
    static func check(_ value: Bool) { precondition(value) }
    static func doc(_ sequence: Int, _ body: String) -> Data {
        Data("---\nid: 2026-11-17-\(sequence)\ndate: 2026-11-17\ntitle: 附近同步检查\n---\n\(body)".utf8)
    }
    static func fixture() throws -> [String: String] {
        let macRaw = Data(repeating: 0, count: 31) + Data([1])
        let androidRaw = Data(repeating: 0, count: 31) + Data([2])
        let mac = try P256.KeyAgreement.PrivateKey(rawRepresentation: macRaw)
        let android = try P256.KeyAgreement.PrivateKey(rawRepresentation: androidRaw)
        let salt = Data((0..<32).map { UInt8(255 - $0) })
        let key = try NearbyCrypto.shared(mac, peer: android.publicKey.x963Representation, salt: salt)
        let reverse = try NearbyCrypto.shared(android, peer: mac.publicKey.x963Representation, salt: salt)
        precondition(key.withUnsafeBytes { Data($0) } == reverse.withUnsafeBytes { Data($0) })
        let plain = Data("附近同步 · Android ↔ macOS".utf8), nonce = Data((0..<12).map(UInt8.init))
        let box = try NearbyCrypto.seal(plain, key: key, context: "network", nonce: nonce)
        let signing = try P256.Signing.PrivateKey(rawRepresentation: macRaw)
        let challenge = NearbyCrypto.identityChallenge(receiver: "receiver", sender: "sender", publicKey: "ephemeral", salt: "salt", senderKey: "senderKey")
        let signature = try signing.signature(for: challenge).derRepresentation.base64EncodedString()
        check(NearbyCrypto.verify(identity: signing.publicKey.x963Representation.base64EncodedString(), signature: signature, data: challenge))
        check(!NearbyCrypto.verify(identity: signing.publicKey.x963Representation.base64EncodedString(), signature: signature,
            data: NearbyCrypto.identityChallenge(receiver: "receiver", sender: "sender", publicKey: "ephemeral", salt: "salt", senderKey: "changed")))
        check(try NearbyCrypto.open(box, key: reverse, context: "network") == plain )
        do { _ = try NearbyCrypto.open(box, key: key, context: "other"); fatalError("AAD accepted") } catch {}
        var damaged = box; damaged[damaged.count - 1] ^= 1
        do { _ = try NearbyCrypto.open(damaged, key: key, context: "network"); fatalError("Tamper accepted") } catch {}
        return ["macPrivate": macRaw.base64EncodedString(), "androidPrivate": androidRaw.base64EncodedString(),
                "macPublic": mac.publicKey.x963Representation.base64EncodedString(), "androidPublic": android.publicKey.x963Representation.base64EncodedString(),
                "salt": salt.base64EncodedString(), "key": key.withUnsafeBytes { Data($0) }.base64EncodedString(),
                "code": NearbyCrypto.code(key), "nonce": nonce.base64EncodedString(), "plain": plain.base64EncodedString(), "box": box.base64EncodedString(),
                "signingIdentity": signing.publicKey.x963Representation.base64EncodedString(), "signature": signature, "challenge": challenge.base64EncodedString(),
                "identityCode": NearbyCrypto.pairCode(key, first: signing.publicKey.x963Representation.base64EncodedString(), second: android.publicKey.x963Representation.base64EncodedString())]
    }
    static func write(_ root: URL, _ path: String, _ data: Data) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    static func main() throws {
        if CommandLine.arguments[1] == "fixture" {
            let data = try JSONSerialization.data(withJSONObject: fixture(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2])); print("PASS: Swift ECDH/HKDF/AES-GCM fixture")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nearby-mac-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Diary"), space = NearbySpace(directory: directory.appendingPathComponent("state"))
        try write(root, b, doc(2, "Mac B"))
        try write(root, image, Data((0..<500_111).map { UInt8($0 % 251) }))
        let port = Int(CommandLine.arguments[2])!
        for round in 1...10 {
            if round == 2 { try write(root, c, doc(3, "Mac C")) }
            if round == 3 { try write(root, a, doc(1, "Mac A3")) }
            if round == 4 || round == 5 {
                var state = try space.load(); let conflict = state.conflicts.first { $0.path == a }!
                state.resolutions[a] = SyncResolution(localSHA: conflict.localSHA, remoteSHA: conflict.remoteSHA, choice: .local)
                try space.save(state)
            }
            if round == 6 { try write(root, c, doc(3, "Mac C6")) }
            let socket = try NearbySocket(host: "127.0.0.1", port: port)
            let wire = NearbyWire(socket: socket, key: SymmetricKey(data: keyBytes))
            defer { wire.close() }
            let local = try space.files.scan(root: root)
            let prepared = try NearbyTransfer.prepare(wire: wire, local: local, space: space, peerId: peer)
            if round == 3 || round == 4 {
                precondition(prepared.conflicts.map(\.path) == [a])
                check(try Data(contentsOf: root.appendingPathComponent(a)) == doc(1, "Mac A3") )
                print("PASS \(round): conflicts retain both versions")
                wire.close(); continue
            }
            precondition(prepared.conflicts.isEmpty)
            if round == 6 {
                do { _ = try wire.request("commit"); fatalError("Concurrent edit overwritten") }
                catch { print("PASS 6: concurrent Android edit rejected") }
                wire.close(); continue
            }
            let committed = try wire.request("commit")
            precondition(committed["type"] as? String == "committed")
            if round == 8 {
                check(try space.load().pending == prepared.hashes )
                print("PASS 8: interrupted after Android commit; Mac journal retained")
                wire.close(); continue
            }
            _ = try space.files.apply(files: prepared.files, expected: local.hashes, root: root)
            var next = NearbyState(); next.base = prepared.hashes
            try space.save(next)
            check(try wire.request("done")["type"] as? String == "ok" )
            space.prune(next)
            check(try space.files.scan(root: root).hashes == prepared.hashes )
            switch round {
            case 1:
                precondition(prepared.files[a] == doc(1, "Android A"))
                precondition(prepared.files[image] == Data((0..<500_111).map { UInt8($0 % 251) }))
                let remoteImage = "entries/2026/11/17/assets/2026-11-17-1/android.png"
                precondition(prepared.files[remoteImage] == Data((0..<600_123).map { UInt8($0 % 239) }))
                precondition(prepared.files.contains { $0.key.hasSuffix("private.md") })
            case 2: precondition(prepared.files[b] == nil && prepared.files[a] == doc(1, "Android A2"))
            case 5: precondition(prepared.files[a] == doc(1, "Mac A3"))
            case 7: precondition(prepared.files[a] == doc(1, "Android A6") && prepared.files[c] == doc(3, "Mac C6"))
            case 9, 10: precondition(prepared.files[a] == doc(1, "Android A8"))
            default: break
            }
            print("PASS \(round): verified bidirectional bytes, baseline and atomic apply")
            wire.close()
        }
        print("PASS: 10 real TCP macOS ↔ Android rounds")
    }
}
