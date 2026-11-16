import CoreLocation
import Foundation
import Observation

enum LocationError: LocalizedError {
    case permissionDenied
    case timeout
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "系统里没有允许「日记」使用定位"
        case .timeout: return "定位超时"
        case .unavailable: return "拿不到当前位置"
        }
    }
}

/// CLLocationManager 的代理单独放一个非隔离的对象，
/// 免得和 @MainActor 的模型混在一起。
private final class LocationDelegateBox: NSObject, CLLocationManagerDelegate {
    var onUpdate: ((CLLocation) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        onUpdate?(last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onFailure?(error)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}

@MainActor
@Observable
final class LocationService {
    private(set) var status: CLAuthorizationStatus
    private(set) var isFetching = false

    private let manager = CLLocationManager()
    private let box = LocationDelegateBox()
    private var pending: CheckedContinuation<CLLocation, Error>?

    init() {
        status = manager.authorizationStatus
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = box

        box.onUpdate = { [weak self] location in
            Task { @MainActor in self?.finish(.success(location)) }
        }
        box.onFailure = { [weak self] error in
            Task { @MainActor in self?.finish(.failure(error)) }
        }
        box.onAuthorizationChange = { [weak self] newStatus in
            Task { @MainActor in self?.status = newStatus }
        }
    }

    var isAuthorized: Bool {
        status == .authorized || status == .authorizedAlways
    }

    var isDenied: Bool {
        status == .denied || status == .restricted
    }

    /// 会先要系统授权；用户拒绝就抛错，界面上退化成手动填写。
    func currentLocation() async throws -> CLLocation {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // 系统授权框要用户自己点，给足时间；期间一旦状态变化立刻继续，
            // 避免「用户点了允许，但这一条日记没记上」。
            for _ in 0..<240 {
                try await Task.sleep(for: .milliseconds(250))
                if status != .notDetermined { break }
            }
        }

        guard isAuthorized else { throw LocationError.permissionDenied }

        isFetching = true
        defer { isFetching = false }

        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                if pending != nil {
                    finish(.failure(LocationError.timeout))
                }
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(with: result)
    }
}

// MARK: - 反查地名

struct ReverseGeocoder {
    func placeComponents(for location: CLLocation) async -> PlaceComponents? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(
                location,
                preferredLocale: Locale(identifier: "zh_Hans_CN")
            ) { placemarks, _ in
                guard let placemark = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: PlaceComponents(
                    country: placemark.country,
                    province: placemark.administrativeArea,
                    city: placemark.locality,
                    district: placemark.subLocality,
                    street: placemark.thoroughfare
                ))
            }
        }
    }
}
