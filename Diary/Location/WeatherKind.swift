import Foundation

/// 天气是有限集合，手填时也从这个枚举里选，不再让用户随便输。
/// 文案与 WMO 代码一一对应，这样自动记录和手填的结果能归到同一个筛选项里。
enum WeatherKind: String, CaseIterable, Identifiable {
    case sunny
    case mostlySunny
    case partlyCloudy
    case overcast
    case fog
    case drizzle
    case sleet
    case lightRain
    case moderateRain
    case heavyRain
    case snow
    case snowGrains
    case showers
    case snowShowers
    case thunderstorm
    case thunderstormHail
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sunny: return "晴"
        case .mostlySunny: return "晴间少云"
        case .partlyCloudy: return "多云"
        case .overcast: return "阴"
        case .fog: return "雾"
        case .drizzle: return "毛毛雨"
        case .sleet: return "冻雨"
        case .lightRain: return "小雨"
        case .moderateRain: return "中雨"
        case .heavyRain: return "大雨"
        case .snow: return "雪"
        case .snowGrains: return "雪粒"
        case .showers: return "阵雨"
        case .snowShowers: return "阵雪"
        case .thunderstorm: return "雷阵雨"
        case .thunderstormHail: return "雷阵雨伴冰雹"
        case .unknown: return "未知"
        }
    }

    var symbol: String {
        switch self {
        case .sunny: return "sun.max"
        case .mostlySunny, .partlyCloudy: return "cloud.sun"
        case .overcast: return "cloud"
        case .fog: return "cloud.fog"
        case .drizzle: return "cloud.drizzle"
        case .sleet: return "cloud.sleet"
        case .lightRain, .moderateRain: return "cloud.rain"
        case .heavyRain: return "cloud.heavyrain"
        case .snow, .snowGrains: return "cloud.snow"
        case .showers: return "cloud.rain"
        case .snowShowers: return "cloud.snow"
        case .thunderstorm, .thunderstormHail: return "cloud.bolt.rain"
        case .unknown: return "cloud"
        }
    }

    /// 存进文件的是一个有代表性的 WMO 代码，只为还原图标用。
    var wmoCode: Int {
        switch self {
        case .sunny: return 0
        case .mostlySunny: return 1
        case .partlyCloudy: return 2
        case .overcast: return 3
        case .fog: return 45
        case .drizzle: return 51
        case .sleet: return 56
        case .lightRain: return 61
        case .moderateRain: return 63
        case .heavyRain: return 65
        case .snow: return 71
        case .snowGrains: return 77
        case .showers: return 80
        case .snowShowers: return 85
        case .thunderstorm: return 95
        case .thunderstormHail: return 99
        case .unknown: return -1
        }
    }

    /// 选择列表里不显示「未知」。
    static var selectable: [WeatherKind] {
        allCases.filter { $0 != .unknown }
    }

    static func from(wmoCode: Int) -> WeatherKind {
        switch wmoCode {
        case 0: return .sunny
        case 1: return .mostlySunny
        case 2: return .partlyCloudy
        case 3: return .overcast
        case 45, 48: return .fog
        case 51, 53, 55: return .drizzle
        case 56, 57, 66, 67: return .sleet
        case 61: return .lightRain
        case 63: return .moderateRain
        case 65: return .heavyRain
        case 71, 73, 75: return .snow
        case 77: return .snowGrains
        case 80, 81, 82: return .showers
        case 85, 86: return .snowShowers
        case 95: return .thunderstorm
        case 96, 99: return .thunderstormHail
        default: return .unknown
        }
    }

    /// 老文件里只有中文文案，用它回显手填表单。
    static func from(text: String?) -> WeatherKind {
        guard let text else { return .unknown }
        return selectable.first { $0.displayName == text } ?? .unknown
    }
}
