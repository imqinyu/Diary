import Foundation

struct WeatherSnapshot {
    var text: String
    var symbol: String
    var temperature: Double
    var code: Int
}

enum WeatherError: LocalizedError {
    case badResponse
    case decoding

    var errorDescription: String? {
        switch self {
        case .badResponse: return "天气服务没有正常返回"
        case .decoding: return "天气数据看不懂"
        }
    }
}

/// 用 Open-Meteo：免费、不用注册、不用 API Key，适合这种纯本地的小工具。
struct WeatherService {

    func current(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { throw WeatherError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherError.badResponse
        }
        guard let decoded = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data) else {
            throw WeatherError.decoding
        }

        let description = Self.describe(code: decoded.current.weather_code)
        return WeatherSnapshot(
            text: description.text,
            symbol: description.symbol,
            temperature: decoded.current.temperature_2m,
            code: decoded.current.weather_code
        )
    }

    // MARK: - WMO 天气代码

    /// 唯一真源是 WeatherKind，自动记录和手填走同一套文案与图标。
    static func describe(code: Int) -> (text: String, symbol: String) {
        let kind = WeatherKind.from(wmoCode: code)
        return (kind.displayName, kind.symbol)
    }

    static func kind(for code: Int) -> WeatherKind {
        WeatherKind.from(wmoCode: code)
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
    }

    let current: Current
}
