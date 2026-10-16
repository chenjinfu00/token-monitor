import SwiftUI
import AppKit

enum WidgetLayout {
    static func panelWidth(compact: Bool) -> CGFloat { compact ? 320 : 340 }
    static func providerHeightLimit(compact: Bool) -> CGFloat { compact ? 340 : 360 }
    static let panelInset: CGFloat = 12
    static let rowHeight: CGFloat = 18
    static let rowSpacing: CGFloat = 6
    static let dateColumnWidth: CGFloat = 94
    static let columnSpacing: CGFloat = 4
}

enum WidgetAppearance {
    static func quotaColor(_ pace: QuotaPace) -> Color {
        switch pace {
        case .ahead: return .codexGreen
        case .balanced: return .paceYellow
        case .behind: return .paceRed
        case .unknown: return .secondary
        }
    }
}

extension WebsiteResetReference.Confidence {
    var color: Color {
        switch self {
        case .unknown, .low: return .secondary
        case .medium: return .claudeOrange
        case .high: return .websitePurple
        case .announced: return .codexGreen
        }
    }
}

extension Color {
    static let codexGreen = adaptive(light: NSColor(red: 0.08, green: 0.48, blue: 0.32, alpha: 1),
        dark: NSColor(red: 0.35, green: 0.81, blue: 0.61, alpha: 1))
    static let claudeOrange = adaptive(light: NSColor(red: 0.72, green: 0.34, blue: 0.17, alpha: 1),
        dark: NSColor(red: 0.96, green: 0.64, blue: 0.45, alpha: 1))
    static let claudeBrandOrange = adaptive(light: NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1),
        dark: NSColor(red: 0.96, green: 0.64, blue: 0.45, alpha: 1))
    static let timeBlue = adaptive(light: NSColor(red: 0.13, green: 0.39, blue: 0.74, alpha: 1),
        dark: NSColor(red: 0.42, green: 0.68, blue: 1.00, alpha: 1))
    static let paceYellow = adaptive(light: NSColor(red: 0.66, green: 0.43, blue: 0.03, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.80, blue: 0.30, alpha: 1))
    static let paceRed = adaptive(light: NSColor(red: 0.77, green: 0.18, blue: 0.22, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.43, blue: 0.45, alpha: 1))
    static let websitePurple = adaptive(light: NSColor(red: 0.53, green: 0.32, blue: 0.78, alpha: 1),
        dark: NSColor(red: 0.74, green: 0.58, blue: 0.98, alpha: 1))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
