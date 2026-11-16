import Foundation
import LocalAuthentication

/// 触控 ID 解锁。设备不支持或用户没录指纹时安静地返回 false，
/// 界面照旧回落到输入密码。
enum BiometricAuthenticator {
    static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        let ok = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ok
    }

    static var biometryName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "触控 ID"
        }
        switch context.biometryType {
        case .touchID: return "触控 ID"
        case .opticID: return "光学 ID"
        case .faceID: return "面容 ID"
        default: return "触控 ID"
        }
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }
}
