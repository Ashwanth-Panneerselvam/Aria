import Foundation
import Combine

/// Owns `SoundProcessingSettings` (crossfeed, personal tuning, hearing
/// profile) and persists them. `ContentView` forwards every change to
/// `PlayerManager.applySoundProcessing`, which reaches the live audio tap.
final class SoundProcessingManager: ObservableObject {
    static let storageKey = "sound_processing_v1"

    @Published var settings: SoundProcessingSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(SoundProcessingSettings.self, from: data) {
            settings = decoded
        } else {
            settings = SoundProcessingSettings()
        }
    }

    var config: DAPConfig { settings.makeConfig() }

    func resetTuning() {
        settings.bassDB = 0
        settings.warmthDB = 0
        settings.presenceDB = 0
        settings.trebleDB = 0
    }

    func saveHearingProfile(_ profile: HearingProfile) {
        settings.hearing = profile
        settings.applyHearing = true
    }

    func deleteHearingProfile() {
        settings.hearing = nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
