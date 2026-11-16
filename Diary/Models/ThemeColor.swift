import SwiftUI

enum ThemeColor: String, CaseIterable, Identifiable {
    case system, blue, teal, green, orange, pink, purple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .blue: return "海蓝"
        case .teal: return "青绿"
        case .green: return "草绿"
        case .orange: return "暖橙"
        case .pink: return "玫瑰"
        case .purple: return "紫罗兰"
        }
    }

    /// nil 让 SwiftUI 继续使用系统强调色。
    var color: Color? {
        switch self {
        case .system: return nil
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .purple: return .purple
        }
    }
}
