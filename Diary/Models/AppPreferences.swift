import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    var locationDetail: LocationDetail {
        didSet {
            defaults.set(locationDetail.rawValue, forKey: Keys.locationDetail)
        }
    }

    /// 打开后，新建条目会自动记一次位置和天气（不再逐条弹确认）。
    /// 关着的时候一切照旧，必须手动点「记录位置与天气」并确认。
    var autoFillMeta: Bool {
        didSet {
            defaults.set(autoFillMeta, forKey: Keys.autoFillMeta)
        }
    }

    var themeColor: ThemeColor {
        didSet {
            defaults.set(themeColor.rawValue, forKey: Keys.themeColor)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let locationDetail = "LocationDetailLevel"
        static let autoFillMeta = "AutoFillLocationAndWeather"
        static let themeColor = "AppThemeColor"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Keys.locationDetail)
        locationDetail = LocationDetail(rawValue: raw ?? "") ?? .district
        autoFillMeta = defaults.object(forKey: Keys.autoFillMeta) as? Bool ?? false
        themeColor = ThemeColor(rawValue: defaults.string(forKey: Keys.themeColor) ?? "") ?? .system
    }
}
