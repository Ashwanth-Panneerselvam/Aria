import SwiftUI
import Combine

@MainActor final class ThemeManager: ObservableObject {
    @Published var theme: AppTheme = .default
    /// Runtime appearance. `SettingsManager.appearanceMode` is its persisted
    /// copy, written only through `setAppearance(_:)` — the same pattern as
    /// `theme` / `selectedThemeID`, so there is one writer and no drift.
    @Published private(set) var appearance: AppearanceMode = .default

    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
        self.appearance = settings.appearanceMode
        if let t = AppTheme.allThemes.first(where: { $0.id == settings.selectedThemeID }) {
            self.theme = t
        }
    }

    func selectTheme(_ theme: AppTheme) {
        self.theme = theme
        settings.setTheme(theme.id)
    }

    /// Switches appearance immediately and persists it. Touches only the
    /// appearance keys — theme, EQ and library state are untouched.
    func setAppearance(_ mode: AppearanceMode) {
        guard mode != appearance else { return }
        appearance = mode
        settings.setAppearance(mode)
    }

    /// Light vs. dark only. True Black reports `true`.
    var isDarkMode: Bool { appearance.isDark }

    var isOLED: Bool { appearance == .oledBlack }

    var colorScheme: ColorScheme { appearance.colorScheme }

    // MARK: - Token API (preferred)

    var tokens: DesignTokens {
        DesignTokens(appearance: appearance, accent: theme.accentColor)
    }

    /// Reasonable default tokens for views that need a `DesignTokens`
    /// value without access to a live `ThemeManager` instance (e.g. a
    /// shared view's default parameter value). Matches `AppTheme.default`
    /// in dark mode, which is the app's default appearance.
    static var fallbackTokens: DesignTokens {
        DesignTokens(isDark: true, accent: AppTheme.default.accentColor)
    }

    // MARK: - Legacy convenience (kept for existing call-sites)

    var background: Color { tokens.background }
    var surface: Color { tokens.surface }
    var textPrimary: Color { tokens.textPrimary }
    var textSecondary: Color { tokens.textSecondary }
    var dividerColor: Color { tokens.dividerColor }
}

/// Strongly-typed design tokens that depend on the current theme & mode.
///
/// Light and Dark values are unchanged from v1. True Black (OLED) uses the
/// palette from the OLED DAP spec: pure black dominates, and the two grey
/// surfaces are reserved for places where hierarchy genuinely needs them.
struct DesignTokens {
    let appearance: AppearanceMode
    let accent: Color

    init(appearance: AppearanceMode, accent: Color) {
        self.appearance = appearance
        self.accent = accent
    }

    /// v1 initializer, kept for previews/tests that only know light vs. dark.
    init(isDark: Bool, accent: Color) {
        self.init(appearance: isDark ? .dark : .light, accent: accent)
    }

    var isDark: Bool { appearance.isDark }
    var isOLED: Bool { appearance == .oledBlack }

    /// OLED palette (sRGB hex from the spec).
    enum OLED {
        static let background = Color(white: 0)                 // #000000
        static let surface = Color(white: 14.0 / 255.0)         // #0E0E0E
        static let elevated = Color(white: 21.0 / 255.0)        // #151515
        static let border = Color(white: 36.0 / 255.0)          // #242424
        static let textPrimary = Color(white: 1)                // #FFFFFF
        static let textSecondary = Color(white: 168.0 / 255.0)  // #A8A8A8
        static let textDisabled = Color(white: 112.0 / 255.0)   // #707070
    }

    var background: Color {
        switch appearance {
        case .oledBlack: return OLED.background
        case .dark:      return Color(red: 0.04, green: 0.04, blue: 0.05)
        case .light:     return Color(red: 0.98, green: 0.98, blue: 0.99)
        }
    }

    var surface: Color {
        switch appearance {
        case .oledBlack: return OLED.surface
        case .dark:      return Color(white: 0.10)
        case .light:     return Color(white: 0.96)
        }
    }

    /// Slightly tinted surface used for "card" backgrounds.
    var cardSurface: Color {
        switch appearance {
        case .oledBlack: return OLED.surface
        case .dark:      return Color(white: 0.12)
        case .light:     return Color.white
        }
    }

    /// Floating elements: toasts, banners, popovers, pressed pills.
    var elevatedSurface: Color {
        switch appearance {
        case .oledBlack: return OLED.elevated
        case .dark:      return Color(white: 0.16)
        case .light:     return Color.white
        }
    }

    /// Persistent chrome (custom tab bar). Black in OLED so the bar melts into
    /// the screen; a top hairline (`chromeBorder`) separates it instead.
    var chromeBackground: Color {
        isOLED ? OLED.background : surface
    }

    /// Hairline drawn above the tab bar / mini player. Clear outside OLED,
    /// where the surface colour change already separates them.
    var chromeBorder: Color {
        isOLED ? OLED.border : Color.clear
    }

    var textPrimary: Color {
        switch appearance {
        case .oledBlack: return OLED.textPrimary
        case .dark:      return Color.white
        case .light:     return Color(red: 0.07, green: 0.07, blue: 0.08)
        }
    }

    var textSecondary: Color {
        // Light 0.45→0.40 lifts secondary text on the ~0.96 background from
        // ~4.35:1 to ~5.2:1, clearing the WCAG AA 4.5:1 threshold for small
        // text. Dark (0.62 on ~0.10) is already ~6:1. OLED #A8A8A8 on black
        // is ~9:1.
        switch appearance {
        case .oledBlack: return OLED.textSecondary
        case .dark:      return Color(white: 0.62)
        case .light:     return Color(white: 0.40)
        }
    }

    /// Disabled controls and de-emphasised metadata.
    var textDisabled: Color {
        switch appearance {
        case .oledBlack: return OLED.textDisabled
        case .dark:      return Color(white: 0.42)
        case .light:     return Color(white: 0.62)
        }
    }

    var dividerColor: Color {
        switch appearance {
        case .oledBlack: return OLED.border
        case .dark:      return Color.white.opacity(0.08)
        case .light:     return Color.black.opacity(0.08)
        }
    }

    var hairline: Color {
        switch appearance {
        case .oledBlack: return OLED.border
        case .dark:      return Color.white.opacity(0.06)
        case .light:     return Color.black.opacity(0.06)
        }
    }

    /// Soft accent wash for active rows / pills. Slightly weaker on pure
    /// black, where the same opacity reads brighter.
    var accentSubtle: Color {
        accent.opacity(isOLED ? 0.16 : 0.18)
    }
}
