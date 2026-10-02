import SwiftUI
import AppKit

/// 背景色。默认深色，可在四种之间切换（类似 Lightroom）。
enum AppBackground: String, CaseIterable, Identifiable, Sendable {
    case white
    case lightGray
    case neutralGray
    case black

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .white: return "白色"
        case .lightGray: return "浅灰"
        case .neutralGray: return "中性灰"
        case .black: return "黑色"
        }
    }

    var color: Color {
        switch self {
        case .white: return Color(white: 1.0)
        case .lightGray: return Color(white: 0.92)
        case .neutralGray: return Color(white: 0.27)
        case .black: return Color(white: 0.06)
        }
    }

    /// 控件明暗跟随背景亮度，否则白底配深色控件会显得很脏。
    var isDark: Bool {
        switch self {
        case .white, .lightGray: return false
        case .neutralGray, .black: return true
        }
    }

    /// 给 AppKit 视图（大图画布）用的颜色。
    var nsColor: NSColor {
        switch self {
        case .white: return NSColor(white: 1.0, alpha: 1)
        case .lightGray: return NSColor(white: 0.92, alpha: 1)
        case .neutralGray: return NSColor(white: 0.27, alpha: 1)
        case .black: return NSColor(white: 0.06, alpha: 1)
        }
    }
}

struct AppTheme {
    var background: AppBackground

    var backgroundColor: Color { background.color }
    var colorScheme: ColorScheme { background.isDark ? .dark : .light }

    /// 主文字与次要文字，保证在四种背景下都有足够对比度。
    var primaryText: Color { background.isDark ? Color(white: 0.95) : Color(white: 0.12) }
    var secondaryText: Color { background.isDark ? Color(white: 0.62) : Color(white: 0.42) }
    var separator: Color { background.isDark ? Color(white: 1.0).opacity(0.12) : Color(white: 0.0).opacity(0.10) }
    var panelBackground: Color {
        background.isDark ? Color(white: 1.0).opacity(0.05) : Color(white: 0.0).opacity(0.03)
    }

    static func from(_ raw: String) -> AppTheme {
        AppTheme(background: AppBackground(rawValue: raw) ?? .neutralGray)
    }
}
