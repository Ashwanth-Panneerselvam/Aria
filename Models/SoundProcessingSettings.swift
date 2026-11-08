import Foundation

/// One measured point from the hearing check: the quietest level (dBFS)
/// still heard at a frequency, through the user's own IEMs and volume.
struct HearingPoint: Codable, Equatable, Hashable {
    var frequency: Double
    var thresholdDBFS: Double
}

struct HearingProfile: Codable, Equatable {
    var points: [HearingPoint]
    var measuredAt: Date

    /// Test frequencies, reference (1 kHz) first.
    static let testFrequencies: [Double] = [1_000, 2_000, 4_000, 8_000, 500, 250, 125]

    /// Typical hearing-threshold shape relative to 1 kHz (ISO 226:2003
    /// threshold of hearing), dB. A person whose relative thresholds match
    /// this gets no correction.
    static let typicalRelativeThreshold: [Double: Double] = [
        125: 19.7, 250: 9.0, 500: 2.0, 1_000: 0, 2_000: -3.7, 4_000: -7.8, 8_000: 10.2,
    ]

    /// How much less (positive) or more (negative) sensitive than typical
    /// at each frequency, relative to the 1 kHz reference.
    var deviations: [(frequency: Double, deviationDB: Double)] {
        guard let ref = points.first(where: { $0.frequency == 1_000 })?.thresholdDBFS else { return [] }
        return points
            .filter { $0.frequency != 1_000 }
            .sorted { $0.frequency < $1.frequency }
            .compactMap { p in
                guard let typical = Self.typicalRelativeThreshold[p.frequency] else { return nil }
                return (p.frequency, (p.thresholdDBFS - ref) - typical)
            }
    }
}

/// User-facing sound processing: crossfeed, taste tuning and an optional
/// hearing-profile correction. Applied after the EQ/AutoEQ stage.
/// Persisted as JSON in UserDefaults (`SoundProcessingManager`).
struct SoundProcessingSettings: Codable, Equatable {

    enum CrossfeedLevel: String, Codable, CaseIterable, Identifiable {
        case off, gentle, natural, strong
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .off: return "Off"
            case .gentle: return "Gentle"
            case .natural: return "Natural"
            case .strong: return "Strong"
            }
        }

        /// bs2b presets: Jan Meier, Chu Moy, bs2b default.
        var parameters: DAPConfig.Crossfeed? {
            switch self {
            case .off: return nil
            case .gentle: return DAPConfig.Crossfeed(cutoffHz: 650, feedDB: 9.5)
            case .natural: return DAPConfig.Crossfeed(cutoffHz: 700, feedDB: 6.0)
            case .strong: return DAPConfig.Crossfeed(cutoffHz: 700, feedDB: 4.5)
            }
        }
    }

    var crossfeed: CrossfeedLevel = .off

    var tuningEnabled = true
    var bassDB: Double = 0       // low shelf 105 Hz
    var warmthDB: Double = 0     // bell 250 Hz
    var presenceDB: Double = 0   // bell 3 kHz
    var trebleDB: Double = 0     // high shelf 8 kHz

    var hearing: HearingProfile?
    var applyHearing = true
    /// 0…1 — share of the measured deviation that is corrected.
    var hearingStrength: Double = 0.5

    static let bassRange: ClosedRange<Double> = -6...6
    static let midRange: ClosedRange<Double> = -4...4
    static let trebleRange: ClosedRange<Double> = -6...6

    // MARK: - Derived processing

    var tuningFilters: [DAPConfig.Filter] {
        guard tuningEnabled else { return [] }
        var out: [DAPConfig.Filter] = []
        if bassDB != 0 { out.append(.init(kind: .lowShelf, frequency: 105, gainDB: bassDB, q: 0.7)) }
        if warmthDB != 0 { out.append(.init(kind: .peak, frequency: 250, gainDB: warmthDB, q: 0.8)) }
        if presenceDB != 0 { out.append(.init(kind: .peak, frequency: 3_000, gainDB: presenceDB, q: 0.9)) }
        if trebleDB != 0 { out.append(.init(kind: .highShelf, frequency: 8_000, gainDB: trebleDB, q: 0.7)) }
        return out
    }

    /// Gentle peaks at the test frequencies: boosts capped at +6 dB, cuts
    /// at −3 dB, scaled by `hearingStrength`; tiny corrections skipped.
    var hearingFilters: [DAPConfig.Filter] {
        guard applyHearing, let hearing else { return [] }
        return hearing.deviations.compactMap { d in
            let gain = min(6, max(-3, d.deviationDB * hearingStrength))
            guard abs(gain) >= 0.5 else { return nil }
            return DAPConfig.Filter(kind: .peak, frequency: d.frequency, gainDB: gain, q: 1.2)
        }
    }

    var allFilters: [DAPConfig.Filter] { tuningFilters + hearingFilters }

    /// Combined filter response in dB at `frequency` (48 kHz reference).
    func responseDB(at frequency: Double, filters: [DAPConfig.Filter]? = nil) -> Double {
        (filters ?? allFilters).reduce(0) { sum, f in
            sum + Biquad.design(f.kind, frequency: f.frequency, gainDB: f.gainDB, q: f.q,
                                sampleRate: 48_000).magnitudeDB(at: frequency, sampleRate: 48_000)
        }
    }

    /// Negative gain applied before the filters so boosts can't clip.
    var headroomDB: Double {
        let filters = allFilters
        guard !filters.isEmpty else { return 0 }
        var peak = 0.0
        var f = 20.0
        while f <= 20_000 {
            peak = max(peak, responseDB(at: f, filters: filters))
            f *= 1.12
        }
        return -peak
    }

    func makeConfig() -> DAPConfig {
        DAPConfig(preGainDB: headroomDB, filters: Array(allFilters.prefix(DAPProcessor.maxFilters)),
                  crossfeed: crossfeed.parameters)
    }

    var isTuningFlat: Bool { bassDB == 0 && warmthDB == 0 && presenceDB == 0 && trebleDB == 0 }
}
