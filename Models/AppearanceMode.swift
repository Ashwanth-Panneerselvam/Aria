import SwiftUI

/// The app's appearance: Light, Dark, or True Black (OLED).
///
/// This is the single typed source of truth for appearance. `SettingsManager`
/// persists it under `storageKey`; `ThemeManager` publishes it to views. The
/// legacy `dark_mode` Bool is still written alongside it (see
/// `SettingsManager.save()`) so an older build installed over this one keeps a
/// sensible light/dark choice instead of falling back to its default.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case oledBlack = "oled"

    /// UserDefaults key for the typed value.
    static let storageKey = "appearance_mode"
    /// Pre-v2 Bool key. Read once for migration, then kept in sync.
    static let legacyDarkModeKey = "dark_mode"

    /// Dark was the app's default before this setting existed.
    static let `default`: AppearanceMode = .dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light:     return "Light"
        case .dark:      return "Dark"
        case .oledBlack: return "True Black"
        }
    }

    /// One-line explanation shown under the picker.
    var detail: String {
        switch self {
        case .light:     return "Bright backgrounds."
        case .dark:      return "Dark grey surfaces."
        case .oledBlack: return "Pure black for OLED screens. Saves power and looks seamless."
        }
    }

    /// True Black is a dark scheme as far as UIKit/system UI is concerned, so
    /// file pickers, alerts, keyboards and sheets all render dark.
    var isDark: Bool { self != .light }

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// Resolves the stored appearance, migrating from the legacy Bool.
    ///
    /// - A valid typed value wins.
    /// - An unknown typed value (e.g. written by a future build) falls back to
    ///   the legacy Bool if present, otherwise the default — never a crash.
    /// - No typed value: the legacy Bool decides Dark/Light, so existing users
    ///   keep exactly what they had. A missing Bool means `default`.
    static func resolve(storedRawValue: String?, legacyIsDark: Bool?) -> AppearanceMode {
        if let raw = storedRawValue, let mode = AppearanceMode(rawValue: raw) {
            return mode
        }
        if let legacyIsDark {
            return legacyIsDark ? .dark : .light
        }
        return .default
    }
}
