import CommonCrypto
import CryptoKit
import Foundation

/// 隐私条目的正文加密。
///
/// 设计取舍：
/// - 只加密**正文**，元数据（日期、心情、标签、字数、位置）继续保持明文，
///   否则列表筛选、统计这些功能就没法在锁定状态下工作了。
/// - 密钥由密码 + 盐用 PBKDF2 派生，不落盘；解锁时算一次，上锁就丢掉。
/// - 每个条目用 AES-GCM 独立 nonce，密文以 base64 放在正文位置，
///   文件依然是「front matter + 一段文本」，只是正文不可读。
enum PrivacyCrypto {

    /// 迭代次数。10 万在 M 系列上大约几十毫秒，够挡住离线暴力破解的性价比。
    static let iterations: UInt32 = 120_000

    /// 由密码和盐派生 32 字节密钥。
    static func key(from password: String, salt: String) -> SymmetricKey? {
        guard let saltData = data(fromHex: salt), !saltData.isEmpty else { return nil }
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordLength = password.utf8.count

        let status: Int32 = password.withCString { passwordPointer in
            saltData.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer,
                    passwordLength,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                    saltData.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derived,
                    derived.count
                )
            }
        }

        guard status == kCCSuccess else { return nil }
        return SymmetricKey(data: Data(derived))
    }

    /// 加密正文，返回 base64（nonce + 密文 + tag）。
    static func seal(_ text: String, key: SymmetricKey) -> String? {
        guard let plain = text.data(using: .utf8),
              let sealed = try? AES.GCM.seal(plain, using: key),
              let combined = sealed.combined else { return nil }
        return combined.base64EncodedString()
    }

    /// 解密正文。密钥不对或数据损坏时返回 nil，不抛错也不写坏文件。
    static func open(_ base64: String, key: SymmetricKey) -> String? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let combined = Data(base64Encoded: trimmed),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - 工具

    static func data(fromHex hex: String) -> Data? {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else { return nil }
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
