import Foundation

/// Which interface Aria shows: the standard tabbed app, or the retro Dial
/// player. Persisted like the appearance setting, so Aria reopens in the
/// interface you last used. Switching never touches playback or the queue.
enum InterfaceMode: String, CaseIterable, Identifiable {
    case standard
    case dial

    static let storageKey = "interface_mode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .dial: return "Dial"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "The full app with tabs."
        case .dial: return "A retro player with a haptic wheel and a tiny screen."
        }
    }
}
