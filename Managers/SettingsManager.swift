import Foundation
import Combine

enum DefaultStartTab: String, CaseIterable {
    case library = "Library"
    case favorites = "Favorites"
    case playlists = "Playlists"
    case search = "Search"
    case more = "More"
}

enum SleepTimerDuration: String, CaseIterable {
    case off = "Off"
    case min15 = "15 min"
    case min30 = "30 min"
    case min45 = "45 min"
    case hour1 = "1 hour"
    case hour2 = "2 hours"

    /// The duration in seconds, or `nil` for `.off` (no timer).
    var timeInterval: TimeInterval? {
        switch self {
        case .off:   return nil
        case .min15: return 15 * 60
        case .min30: return 30 * 60
        case .min45: return 45 * 60
        case .hour1: return 60 * 60
        case .hour2: return 2 * 60 * 60
        }
    }
}

final class SettingsManager: ObservableObject {
    /// Library, not Favorites: a first-run user has no favorites and needs
    /// the Import button in front of them. A saved choice still wins (`load()`).
    @Published var defaultStartTab: DefaultStartTab = .library
    /// Light / Dark / True Black. Persisted under `AppearanceMode.storageKey`;
    /// migrated from the legacy `dark_mode` Bool on first launch of v2.
    @Published var appearanceMode: AppearanceMode = .default
    /// Show the source-format strip (codec · bit depth · sample rate · EQ) at
    /// the bottom of the full-screen player.
    @Published var showAudioInfoStrip: Bool = true
    /// Draw the seek bar as the track's loudness waveform (needs analysis).
    @Published var showWaveformSeekBar: Bool = true
    /// The little creature on the Now Playing screen.
    @Published var showPet: Bool = true
    @Published var selectedThemeID: String = "blue"
    @Published var sleepTimer: SleepTimerDuration = .off
    @Published private(set) var searchHistory: [String] = []
    /// Backend server URL / API key overrides (More → Backend). Persisted
    /// under the `BackendConfig` keys so URL resolution sees them; empty
    /// string = no override.
    @Published var backendURLOverride: String = ""
    @Published var backendAPIKeyOverride: String = ""
    /// Which protocol the configured server speaks (Aria backend vs Subsonic).
    @Published var serverKind: BackendConfig.ServerKind = .aria
    @Published var subsonicUsername: String = ""
    /// Mirrored into the Keychain on save — never persisted to UserDefaults.
    @Published var subsonicPassword: String = ""
    /// Set when a Keychain write fails, so Settings can say so rather than let
    /// the password silently vanish on the next launch. See `KeychainStore`.
    @Published private(set) var credentialStorageFailed = false

    /// The backend URL as currently *typed*, not as last saved.
    var resolvedBaseURL: String {
        BackendConfig.baseURL(override: backendURLOverride)
    }

    /// The live server configuration, for building backend clients. Reading
    /// this instead of `BackendConfig.current` keeps the Keychain out of the
    /// per-search path and reflects credentials the moment they're typed.
    var backendSnapshot: BackendConfig.Snapshot {
        BackendConfig.Snapshot(kind: serverKind, baseURL: resolvedBaseURL,
                               subsonicUsername: subsonicUsername,
                               subsonicPassword: subsonicPassword)
    }

    /// Live equivalent of `BackendConfig.isConfigured`, computed from the
    /// published fields.
    ///
    /// Views must use this one. `BackendConfig` reads `UserDefaults`, which
    /// `save()` only writes from an `onChange` — i.e. *after* SwiftUI has
    /// already recomputed the body. A view reading `BackendConfig` directly
    /// therefore renders one edit behind, which is invisible while typing a
    /// URL (the next keystroke catches it up) but sticks on a one-shot change
    /// like the Server Type picker.
    var isServerConfigured: Bool {
        BackendConfig.isConfigured(kind: serverKind, baseURL: resolvedBaseURL,
                                   subsonicUsername: subsonicUsername,
                                   subsonicPassword: subsonicPassword)
    }

    /// Derived from `appearanceMode` — kept so existing call sites that only
    /// care about light vs. dark keep compiling. Not separately stored.
    var isDarkMode: Bool { appearanceMode.isDark }

    static let showAudioInfoStripKey = "show_audio_info_strip"
    static let showWaveformSeekBarKey = "show_waveform_seek_bar"
    static let showPetKey = "show_pet"

    private let maxHistoryItems = 20
    private let defaults = UserDefaults.standard
    /// What the Keychain currently holds, so `save()` only writes on a change.
    private var lastStoredPassword: String?

    init() { load() }

    func addSearchToHistory(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0 == trimmed }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > maxHistoryItems {
            searchHistory = Array(searchHistory.prefix(maxHistoryItems))
        }
        save()
    }

    func removeSearchHistoryItem(_ item: String) {
        searchHistory.removeAll { $0 == item }
        save()
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        save()
    }

    private func load() {
        if let raw = defaults.string(forKey: "default_start_tab"),
           let val = DefaultStartTab(rawValue: raw) { defaultStartTab = val }
        appearanceMode = AppearanceMode.resolve(
            storedRawValue: defaults.string(forKey: AppearanceMode.storageKey),
            legacyIsDark: defaults.object(forKey: AppearanceMode.legacyDarkModeKey) as? Bool
        )
        showAudioInfoStrip = defaults.object(forKey: Self.showAudioInfoStripKey) as? Bool ?? true
        showWaveformSeekBar = defaults.object(forKey: Self.showWaveformSeekBarKey) as? Bool ?? true
        showPet = defaults.object(forKey: Self.showPetKey) as? Bool ?? true
        selectedThemeID = defaults.string(forKey: "theme_id") ?? "blue"
        // The sleep timer is intentionally NOT restored. It's ephemeral —
        // nothing re-arms it at launch, so restoring a stale "30 min"
        // selection would show a duration with no running timer. It always
        // starts at `.off` each launch.
        if let history = defaults.stringArray(forKey: "search_history") {
            searchHistory = history
        }
        backendURLOverride = defaults.string(forKey: BackendConfig.urlOverrideKey) ?? ""
        backendAPIKeyOverride = defaults.string(forKey: BackendConfig.apiKeyOverrideKey) ?? ""
        serverKind = BackendConfig.ServerKind(rawValue: defaults.string(forKey: BackendConfig.serverKindKey) ?? "") ?? .aria
        subsonicUsername = defaults.string(forKey: BackendConfig.subsonicUsernameKey) ?? ""
        subsonicPassword = KeychainStore.get(account: KeychainStore.subsonicPasswordAccount) ?? ""
        lastStoredPassword = subsonicPassword
    }

    func save() {
        defaults.set(defaultStartTab.rawValue, forKey: "default_start_tab")
        defaults.set(appearanceMode.rawValue, forKey: AppearanceMode.storageKey)
        // Keep the legacy Bool in step so rolling back to a pre-v2 build
        // lands on Dark (for Dark or True Black) rather than its default.
        defaults.set(appearanceMode.isDark, forKey: AppearanceMode.legacyDarkModeKey)
        defaults.set(showAudioInfoStrip, forKey: Self.showAudioInfoStripKey)
        defaults.set(showWaveformSeekBar, forKey: Self.showWaveformSeekBarKey)
        defaults.set(showPet, forKey: Self.showPetKey)
        defaults.set(selectedThemeID, forKey: "theme_id")
        // Sleep timer is ephemeral and deliberately not persisted (see load()).
        defaults.set(searchHistory, forKey: "search_history")
        defaults.set(backendURLOverride, forKey: BackendConfig.urlOverrideKey)
        defaults.set(backendAPIKeyOverride, forKey: BackendConfig.apiKeyOverrideKey)
        defaults.set(serverKind.rawValue, forKey: BackendConfig.serverKindKey)
        defaults.set(subsonicUsername, forKey: BackendConfig.subsonicUsernameKey)
        // The password is a real credential: Keychain only. Guarded on an
        // actual change — `save()` runs for every settings edit (theme, start
        // page…), and the Keychain is far too expensive to hit each time.
        if subsonicPassword != lastStoredPassword {
            let stored = KeychainStore.set(subsonicPassword,
                                           account: KeychainStore.subsonicPasswordAccount)
            credentialStorageFailed = !stored
            if stored { lastStoredPassword = subsonicPassword }
        }
    }

    func setTheme(_ id: String) {
        selectedThemeID = id
        save()
    }

    func setAppearance(_ mode: AppearanceMode) {
        appearanceMode = mode
        save()
    }
}
