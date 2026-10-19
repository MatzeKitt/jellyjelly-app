import SwiftUI

/// The six color schemes, mirroring JellyGoose's appearance options.
enum ThemeScheme: String, CaseIterable, Identifiable, Codable {
    case violetSignal
    case ember
    case evergreen
    case blueHour
    case roseNoir
    case trueBlack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .violetSignal: String(localized: "Violet Signal")
        case .ember: String(localized: "Ember")
        case .evergreen: String(localized: "Evergreen")
        case .blueHour: String(localized: "Blue Hour")
        case .roseNoir: String(localized: "Rose Noir")
        case .trueBlack: String(localized: "True Black")
        }
    }

    var palette: Palette {
        switch self {
        case .violetSignal:
            Palette(accent: Color(hex: 0xA78BFA), accentDeep: Color(hex: 0x7C3AED),
                    backgroundTop: Color(hex: 0x1A1033), backgroundBottom: Color(hex: 0x0B0814),
                    sidebar: Color(hex: 0x120C22), surface: Color(hex: 0x231840))
        case .ember:
            Palette(accent: Color(hex: 0xFB923C), accentDeep: Color(hex: 0xEA580C),
                    backgroundTop: Color(hex: 0x2A140A), backgroundBottom: Color(hex: 0x100906),
                    sidebar: Color(hex: 0x1C0F08), surface: Color(hex: 0x33190D))
        case .evergreen:
            Palette(accent: Color(hex: 0x34D399), accentDeep: Color(hex: 0x059669),
                    backgroundTop: Color(hex: 0x0C2219), backgroundBottom: Color(hex: 0x050E0A),
                    sidebar: Color(hex: 0x081711), surface: Color(hex: 0x123024))
        case .blueHour:
            Palette(accent: Color(hex: 0x60A5FA), accentDeep: Color(hex: 0x2563EB),
                    backgroundTop: Color(hex: 0x0F1D38), backgroundBottom: Color(hex: 0x060B16),
                    sidebar: Color(hex: 0x0A1428), surface: Color(hex: 0x15274A))
        case .roseNoir:
            Palette(accent: Color(hex: 0xFB7185), accentDeep: Color(hex: 0xE11D48),
                    backgroundTop: Color(hex: 0x2A0F18), backgroundBottom: Color(hex: 0x0F0609),
                    sidebar: Color(hex: 0x1C0A10), surface: Color(hex: 0x36141F))
        case .trueBlack:
            Palette(accent: Color(hex: 0xF5F5F5), accentDeep: Color(hex: 0xA3A3A3),
                    backgroundTop: .black, backgroundBottom: .black,
                    sidebar: Color(hex: 0x0A0A0A), surface: Color(hex: 0x1A1A1A))
        }
    }
}

struct Palette: Equatable {
    var accent: Color
    var accentDeep: Color
    var backgroundTop: Color
    var backgroundBottom: Color
    var sidebar: Color
    var surface: Color

    var text: Color { .white }
    var secondaryText: Color { .white.opacity(0.68) }
    var tertiaryText: Color { .white.opacity(0.45) }
    var hairline: Color { .white.opacity(0.08) }

    /// Text drawn on top of the accent color.
    var onAccent: Color { accent == Color(hex: 0xF5F5F5) ? .black : .white }

    var backgroundGradient: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = ThemeScheme.violetSignal.palette
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Metrics {
    static let pagePadding: CGFloat = 40
    static let cardCorner: CGFloat = 12
    static let shelfSpacing: CGFloat = 18
}
