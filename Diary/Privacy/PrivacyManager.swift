import CryptoKit
import Foundation
import Observation
import Security

/// 隐私正文加密；密码只在解锁期间驻留内存，磁盘保存盐与验证记录。
@MainActor
@Observable
final class PrivacyManager {
    private(set) var hasPassword: Bool
    /// 启动时永远是锁着的；解锁只在本次运行内有效。
    private(set) var isUnlocked = false
    /// 解锁时从密码派生出来的正文密钥，上锁立刻丢掉。
    private(set) var encryptionKey: SymmetricKey?
    var errorMessage: String?

    static let minimumLength = 4

    /// 解锁记录，隐私页里能看最近一周/一月谁在什么时候解开过。
    let auditLog: PrivacyAuditLog

    /// 是否允许用触控 ID 代替输密码。
    var useBiometrics: Bool {
        didSet {
            defaults.set(useBiometrics, forKey: Self.biometricsKey)
        }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var unlockedPassword: String?
    @ObservationIgnored private var derivedKeys: [String: SymmetricKey] = [:]
    private static let storageKey = "PrivacyPasswordRecord"
    private static let biometricsKey = "PrivacyUseBiometrics"

    init(defaults: UserDefaults = .standard, auditLog: PrivacyAuditLog? = nil) {
        self.defaults = defaults
        self.hasPassword = defaults.string(forKey: Self.storageKey) != nil
        self.auditLog = auditLog ?? PrivacyAuditLog()
        self.useBiometrics = defaults.object(forKey: Self.biometricsKey) as? Bool ?? false
    }

    /// 有密码且当前未解锁 = 私密内容需要藏起来。
    var isLocked: Bool {
        hasPassword && !isUnlocked
    }

    /// 没设密码（要来设置），或者已经解锁（可以管理），才显示隐私设置项。
    var canShowSettings: Bool {
        !hasPassword || isUnlocked
    }

    // MARK: - 密码

    @discardableResult
    func setPassword(_ password: String) -> Bool {
        guard password.count >= Self.minimumLength else {
            errorMessage = "密码至少 \(Self.minimumLength) 位"
            return false
        }
        let salt = Self.randomSalt()
        defaults.set("\(salt):\(Self.hash(password, salt: salt))", forKey: Self.storageKey)
        hasPassword = true
        isUnlocked = true
        encryptionKey = PrivacyCrypto.key(from: password, salt: salt)
        unlockedPassword = password
        derivedKeys.removeAll()
        errorMessage = nil
        return true
    }

    @discardableResult
    func changePassword(current: String, new: String) -> Bool {
        guard verify(current) else {
            errorMessage = "当前密码不对"
            return false
        }
        return setPassword(new)
    }

    @discardableResult
    func removePassword(current: String) -> Bool {
        guard verify(current) else {
            errorMessage = "当前密码不对"
            return false
        }
        defaults.removeObject(forKey: Self.storageKey)
        hasPassword = false
        isUnlocked = false
        encryptionKey = nil
        unlockedPassword = nil
        derivedKeys.removeAll()
        errorMessage = nil
        return true
    }

    func verify(_ password: String) -> Bool {
        guard let record = defaults.string(forKey: Self.storageKey) else { return false }
        let parts = record.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let salt = String(parts[0])
        let expected = String(parts[1])
        return Self.constantTimeEquals(Self.hash(password, salt: salt), expected)
    }

    /// 在搜索框里回车时调用。成功就静默解锁，失败就当普通搜索词，不弹任何提示。
    /// 开了触控 ID 时是「密码 + 指纹」双保险：密码对了还要再过一道指纹，
    /// 指纹没过同样记进访问记录。
    @discardableResult
    func tryUnlock(_ password: String) async -> Bool {
        guard hasPassword, !password.isEmpty else { return false }

        guard verify(password) else {
            auditLog.record(method: "密码", success: false)
            return false
        }

        guard useBiometrics, BiometricAuthenticator.isAvailable else {
            auditLog.record(method: "密码", success: true)
            unlock(with: password)
            return true
        }

        let name = BiometricAuthenticator.biometryName
        let passed = await BiometricAuthenticator.authenticate(reason: "解锁隐私日记")
        guard passed else {
            // 密码过了但指纹没过：这也是值得留痕的一次尝试
            auditLog.record(method: "密码通过 · \(name)未通过", success: false)
            return false
        }
        auditLog.record(method: "密码 + \(name)", success: true)
        unlock(with: password)
        return true
    }

    /// 验证通过后统一在这里落地状态和密钥。
    private func unlock(with password: String) {
        isUnlocked = true
        unlockedPassword = password
        derivedKeys.removeAll()
        if let salt = storedSalt {
            encryptionKey = PrivacyCrypto.key(from: password, salt: salt)
        }
    }

    func lock() {
        ThumbnailCache.shared.clear()
        isUnlocked = false
        encryptionKey = nil
        unlockedPassword = nil
        derivedKeys.removeAll()
    }

    /// 盐不是密钥，可以随加密正文保存；不同设备用同一密码派生对应密钥。
    var encryptionSalt: String? { storedSalt }

    func encryptionKey(for salt: String?) -> SymmetricKey? {
        guard let salt else { return encryptionKey }
        guard let password = unlockedPassword, isUnlocked else { return nil }
        if salt == storedSalt { return encryptionKey }
        if let key = derivedKeys[salt] { return key }
        guard salt.count == 32, let key = PrivacyCrypto.key(from: password, salt: salt) else { return nil }
        derivedKeys[salt] = key
        return key
    }

    /// 当前密码记录里的盐，用来派生密钥。
    private var storedSalt: String? {
        guard let record = defaults.string(forKey: Self.storageKey) else { return nil }
        return String(record.split(separator: ":", maxSplits: 1).first ?? "")
    }

    // MARK: - 哈希

    private static func hash(_ password: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + password).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs.utf8, rhs.utf8) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
