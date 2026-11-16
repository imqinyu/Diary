import Foundation

/// 地名详细程度。用户担心暴露行踪就选粗一点。
enum LocationDetail: String, CaseIterable, Identifiable {
    case country
    case province
    case city
    case district
    case street

    var id: String { rawValue }

    var title: String {
        switch self {
        case .country: return "国家"
        case .province: return "省 / 直辖市"
        case .city: return "城市"
        case .district: return "区 / 县"
        case .street: return "街道"
        }
    }

    var example: String {
        switch self {
        case .country: return "中国"
        case .province: return "上海市"
        case .city: return "上海市"
        case .district: return "上海市 徐汇区"
        case .street: return "上海市 徐汇区 衡山路"
        }
    }
}

/// 把地名拆成可组合的几段，方便按详细程度拼。
struct PlaceComponents {
    var country: String?
    var province: String?
    var city: String?
    var district: String?
    var street: String?

    func name(for detail: LocationDetail) -> String {
        let raw: [String?]
        switch detail {
        case .country:
            raw = [country]
        case .province:
            raw = [province ?? city]
        case .city:
            raw = [province, city]
        case .district:
            raw = [city ?? province, district]
        case .street:
            raw = [district ?? city ?? province, street]
        }

        var parts: [String] = []
        for value in raw.compactMap({ $0?.trimmingCharacters(in: .whitespaces) }) where !value.isEmpty {
            if parts.contains(value) { continue }
            parts.append(value)
        }
        return parts.joined(separator: " ")
    }
}
