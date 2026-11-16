import Foundation
import SwiftUI

/// 心情。存进文件的是稳定的字符串键（`happy`），不是枚举序号，
/// 这样以后增删心情、或者别的平台实现时都不会读坏旧文件。
enum Mood: String, CaseIterable, Codable, Identifiable, Hashable {
    case happy
    case calm
    case excited
    case grateful
    case tired
    case anxious
    case sad
    case angry

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .happy: return "开心"
        case .calm: return "平静"
        case .excited: return "兴奋"
        case .grateful: return "感恩"
        case .tired: return "疲惫"
        case .anxious: return "焦虑"
        case .sad: return "难过"
        case .angry: return "生气"
        }
    }

    var symbolName: String {
        switch self {
        case .happy: return "sun.max"
        case .calm: return "leaf"
        case .excited: return "sparkles"
        case .grateful: return "heart"
        case .tired: return "moon.zzz"
        case .anxious: return "wind"
        case .sad: return "cloud.rain"
        case .angry: return "flame"
        }
    }

    var tint: Color {
        switch self {
        case .happy: return .orange
        case .calm: return .teal
        case .excited: return .pink
        case .grateful: return .purple
        case .tired: return .gray
        case .anxious: return .indigo
        case .sad: return .blue
        case .angry: return .red
        }
    }
}
