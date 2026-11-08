import SwiftUI
import UIKit
import XCTest
@testable import Aria___Music_Browser

/// OLED DAP v2: the Light / Dark / True Black appearance setting — migration
/// from the legacy `dark_mode` Bool, persistence, live switching, and the
/// OLED palette.
@MainActor
final class AppearanceModeTests: XCTestCase {

    private let keys = [
        AppearanceMode.storageKey,
        AppearanceMode.legacyDarkModeKey,
        SettingsManager.showAudioInfoStripKey,
        "theme_id",
    ]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        // Hermetic: stash and clear the real values, restore afterwards.
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        saved = [:]
        super.tearDown()
    }

    // MARK: - Resolution / migration

    func test_resolve_typedValueWins() {
        XCTAssertEqual(AppearanceMode.resolve(storedRawValue: "oled", legacyIsDark: false), .oledBlack)
        XCTAssertEqual(AppearanceMode.resolve(storedRawValue: "light", legacyIsDark: true), .light)
    }

    func test_resolve_legacyBoolMigrates() {
        XCTAssertEqual(AppearanceMode.resolve(storedRawValue: nil, legacyIsDark: true), .dark)
        XCTAssertEqual(AppearanceMode.resolve(storedRawValue: nil, legacyIsDark: false), .light)
    }

    func test_resolve_freshInstallDefaultsToDark() {
        XCTAssertEqual(AppearanceMode.resolve(storedRawValue: nil, legacyIsDark: nil), .dark)
    }

    func test_resolve_unknownValueFallsBackSafely() {
        XCTAssertEqual(AppearanceMode.resolve(storedRawValue: "sepia", legacyIsDark: false), .light)
        XCTAssertEqual(AppearanceMode.resolve(storedRawValue: "sepia", legacyIsDark: nil), .default)
    }

    func test_settings_existingLightUserStaysLight() {
        UserDefaults.standard.set(false, forKey: AppearanceMode.legacyDarkModeKey)
        XCTAssertEqual(SettingsManager().appearanceMode, .light)
    }

    func test_settings_existingDarkUserStaysDark() {
        UserDefaults.standard.set(true, forKey: AppearanceMode.legacyDarkModeKey)
        XCTAssertEqual(SettingsManager().appearanceMode, .dark)
    }

    // MARK: - Persistence

    func test_trueBlack_persistsAcrossRelaunch() {
        let settings = SettingsManager()
        settings.setAppearance(.oledBlack)

        XCTAssertEqual(SettingsManager().appearanceMode, .oledBlack)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppearanceMode.storageKey), "oled")
    }

    func test_legacyBoolKeptInSync_forRollback() {
        let settings = SettingsManager()
        settings.setAppearance(.oledBlack)
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppearanceMode.legacyDarkModeKey) as? Bool, true)
        settings.setAppearance(.light)
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppearanceMode.legacyDarkModeKey) as? Bool, false)
    }

    func test_audioInfoStrip_defaultsOnAndPersists() {
        XCTAssertTrue(SettingsManager().showAudioInfoStrip)
        let settings = SettingsManager()
        settings.showAudioInfoStrip = false
        settings.save()
        XCTAssertFalse(SettingsManager().showAudioInfoStrip)
    }

    // MARK: - ThemeManager

    func test_themeManager_switchesImmediatelyAndPersists() {
        let settings = SettingsManager()
        let theme = ThemeManager(settings: settings)

        theme.setAppearance(.oledBlack)
        XCTAssertEqual(theme.appearance, .oledBlack)
        XCTAssertTrue(theme.isOLED)
        XCTAssertTrue(theme.isDarkMode)
        XCTAssertEqual(theme.colorScheme, .dark, "True Black must render system UI dark")
        XCTAssertTrue(theme.tokens.isOLED)
        XCTAssertEqual(settings.appearanceMode, .oledBlack, "single persisted copy stays in step")

        theme.setAppearance(.light)
        XCTAssertEqual(theme.colorScheme, .light)
        XCTAssertFalse(theme.tokens.isDark)
    }

    func test_changingAppearance_keepsAccentTheme() {
        UserDefaults.standard.set("rose", forKey: "theme_id")
        let settings = SettingsManager()
        let theme = ThemeManager(settings: settings)
        XCTAssertEqual(theme.theme.id, "rose")

        theme.setAppearance(.oledBlack)

        XCTAssertEqual(theme.theme.id, "rose")
        XCTAssertEqual(SettingsManager().selectedThemeID, "rose")
    }

    // MARK: - Tokens

    func test_oledTokens_matchSpecPalette() {
        let t = DesignTokens(appearance: .oledBlack, accent: AppTheme.default.accentColor)
        assertGrey(t.background, 0, "background #000000")
        assertGrey(t.surface, 14, "surface #0E0E0E")
        assertGrey(t.elevatedSurface, 21, "elevated #151515")
        assertGrey(t.dividerColor, 36, "divider #242424")
        assertGrey(t.textPrimary, 255, "text #FFFFFF")
        assertGrey(t.textSecondary, 168, "secondary #A8A8A8")
        assertGrey(t.textDisabled, 112, "disabled #707070")
        assertGrey(t.chromeBackground, 0, "tab bar is pure black")
    }

    func test_darkAndLightTokens_unchangedFromV1() {
        let dark = DesignTokens(isDark: true, accent: .blue)
        let light = DesignTokens(isDark: false, accent: .blue)
        XCTAssertEqual(dark.appearance, .dark)
        XCTAssertEqual(light.appearance, .light)
        assertRGB(dark.background, (0.04, 0.04, 0.05))
        assertRGB(light.background, (0.98, 0.98, 0.99))
        assertRGB(dark.surface, (0.10, 0.10, 0.10))
    }

    /// Every built-in accent must stay legible as text on pure black
    /// (WCAG AA, 4.5:1).
    func test_allAccents_meetContrastOnBlack() {
        for theme in AppTheme.allThemes {
            let ratio = contrastRatio(theme.accentColor, on: .black)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.name) accent is \(ratio):1 on black")
        }
    }

    func test_oledSecondaryText_meetsContrast() {
        let t = DesignTokens(appearance: .oledBlack, accent: .blue)
        XCTAssertGreaterThanOrEqual(contrastRatio(t.textSecondary, on: t.background), 7)
    }

    // MARK: - Helpers

    private func components(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private func assertGrey(_ color: Color, _ value255: Int, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let c = components(color)
        let expected = CGFloat(value255) / 255
        XCTAssertEqual(c.r, expected, accuracy: 0.003, message, file: file, line: line)
        XCTAssertEqual(c.g, expected, accuracy: 0.003, message, file: file, line: line)
        XCTAssertEqual(c.b, expected, accuracy: 0.003, message, file: file, line: line)
        XCTAssertEqual(c.a, 1, accuracy: 0.001, message, file: file, line: line)
    }

    private func assertRGB(_ color: Color, _ rgb: (CGFloat, CGFloat, CGFloat),
                           file: StaticString = #filePath, line: UInt = #line) {
        let c = components(color)
        XCTAssertEqual(c.r, rgb.0, accuracy: 0.003, file: file, line: line)
        XCTAssertEqual(c.g, rgb.1, accuracy: 0.003, file: file, line: line)
        XCTAssertEqual(c.b, rgb.2, accuracy: 0.003, file: file, line: line)
    }

    private func luminance(_ color: Color) -> CGFloat {
        let c = components(color)
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func contrastRatio(_ a: Color, on b: Color) -> CGFloat {
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
