import Foundation
import Combine

/// The little creature that lives on the Now Playing screen. It remembers
/// how many days you've listened (it grows up) and, for this session, how
/// often each track has played (it gets excited by new ones and bored by
/// repeats). Nothing here affects playback.
@MainActor
final class PetStore: ObservableObject {

    enum Mood: Equatable {
        case sleeping   // nothing playing
        case dancing    // playing
        case excited    // just started a track it hasn't heard this session
        case bored      // this track has played 3+ times this session
    }

    enum Stage: Int, Comparable {
        case baby = 0, kid, grown
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .baby: return "baby"
            case .kid: return "kid"
            case .grown: return "grown-up"
            }
        }
    }

    static let storageKey = "pet_v1"
    static let excitedSeconds: TimeInterval = 8
    static let boredAfterPlays = 3

    private struct Persisted: Codable {
        var bornAt: Date
        var listenDays: [String]
    }

    @Published private(set) var bornAt: Date
    @Published private(set) var listenDays: Set<String>
    @Published private(set) var excitedUntil: Date?
    @Published private(set) var currentTrackPlays = 0

    private var sessionPlays: [String: Int] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            bornAt = p.bornAt
            listenDays = Set(p.listenDays)
        } else {
            bornAt = Date()
            listenDays = []
        }
    }

    /// Grows up after 3 and 10 distinct days of listening.
    var stage: Stage {
        switch listenDays.count {
        case ..<3: return .baby
        case ..<10: return .kid
        default: return .grown
        }
    }

    func mood(isPlaying: Bool, now: Date = Date()) -> Mood {
        guard isPlaying else { return .sleeping }
        if let until = excitedUntil, now < until { return .excited }
        if currentTrackPlays >= Self.boredAfterPlays { return .bored }
        return .dancing
    }

    /// Call whenever a new track starts (any track id; nil when cleared).
    func trackStarted(_ id: String?, now: Date = Date()) {
        guard let id else {
            currentTrackPlays = 0
            excitedUntil = nil
            return
        }
        let plays = (sessionPlays[id] ?? 0) + 1
        sessionPlays[id] = plays
        currentTrackPlays = plays
        excitedUntil = plays == 1 ? now.addingTimeInterval(Self.excitedSeconds) : nil
        recordListenDay(now)
    }

    private func recordListenDay(_ date: Date) {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        guard !listenDays.contains(day) else { return }
        listenDays.insert(day)
        // Only the count matters; keep the stored list bounded.
        if listenDays.count > 400 {
            listenDays = Set(listenDays.sorted().suffix(400))
        }
        save()
    }

    private func save() {
        let p = Persisted(bornAt: bornAt, listenDays: listenDays.sorted())
        if let data = try? JSONEncoder().encode(p) { defaults.set(data, forKey: Self.storageKey) }
    }
}
