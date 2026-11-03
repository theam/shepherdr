import SwiftUI
import UIKit

/// Shepherdr's phosphor console, as the Mac app paints it (App/Theme.swift).
enum Theme {
    static let background = Color(hex: 0x090C0A)
    static let panel = Color(hex: 0x0E1310)
    static let raised = Color(hex: 0x141B17)
    static let line = Color(hex: 0x1F2B25)
    static let text = Color(hex: 0xD9E7DE)
    static let dim = Color(hex: 0x7E9488)
    static let faint = Color(hex: 0x4B5E53)
    static let phosphor = Color(hex: 0x4DFFA0)
    static let amber = Color(hex: 0xFFB547)
    static let cyan = Color(hex: 0x5CD6FF)
    static let red = Color(hex: 0xFF5F57)
    static let lilac = Color(hex: 0xD77CFF)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .bold, .heavy, .black: "FiraCode-Bold"
        case .semibold: "FiraCode-SemiBold"
        case .medium: "FiraCode-Medium"
        default: "FiraCode-Regular"
        }
        return UIFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: weight, design: .monospaced)
    }

    static func terminalFont(size: CGFloat) -> UIFont {
        UIFont(name: "FiraCode-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The color a session's status shows in, as the Mac's queue does.
    static func color(forStatus status: String?) -> Color {
        switch status {
        case "needsYou": amber
        case "working", "running": phosphor
        case "waiting": lilac
        case "done", "finished": cyan
        case "stale": red
        default: dim
        }
    }

    static func label(forStatus status: String?) -> String {
        switch status {
        case "needsYou": "NEEDS YOU"
        case "waiting": "ON HOLD"
        case let status?: status.uppercased()
        case nil: ""
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
