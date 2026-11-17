import Foundation

/// Volume leveling: plays every track at the same perceived loudness.
///
/// How it works: each track's loudness is known either from Aria's own
/// measurement (ITU-R BS.1770 integrated loudness, from `TrackAnalyzer`) or
/// from ReplayGain tags already in the file. The player applies one fixed gain
/// per track — `target − loudness` — so a loud modern master is turned down
/// and a quiet older one turned up. It is a single volume change per track,
/// not compression: the music's own dynamics are untouched.
///
/// Album mode applies one gain to a whole album instead, so the quiet intro
/// track of an album stays quieter than its loud single, as mastered.
nonisolated struct VolumeLevelingSettings: Codable, Equatable {

    enum Mode: String, Codable, CaseIterable, Identifiable {
        /// Every track at the same loudness.
        case track
        /// Every album at the same loudness; tracks keep their relative levels.
        case album
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .track: return "Track"
            case .album: return "Album"
            }
        }
    }

    /// Named reference points on the level slider (and the settings an
    /// earlier version stored).
    enum Level: String, Codable, CaseIterable, Identifiable {
        case quiet, normal, loud
        var id: String { rawValue }

        /// Target integrated loudness, LUFS.
        var targetLUFS: Double {
            switch self {
            case .loud: return -14
            case .normal: return -16
            case .quiet: return -18
            }
        }

        var displayName: String {
            switch self {
            case .loud: return "Loud"
            case .normal: return "Normal"
            case .quiet: return "Quiet"
            }
        }
    }

    /// Slider range for the target loudness, LUFS, and its step.
    static let targetRange: ClosedRange<Double> = -24 ... -10
    static let targetStep = 0.5

    var enabled = true
    var mode: Mode = .track
    /// The loudness every track (or album) is brought to, LUFS. Set with a
    /// slider; Loud/Normal/Quiet are marked on it.
    var targetLUFS: Double = Level.normal.targetLUFS {
        didSet {
            let clamped = Self.snap(targetLUFS)
            if clamped != targetLUFS { targetLUFS = clamped }
        }
    }
    /// When true, quiet tracks are only raised as far as their peaks allow,
    /// so nothing is ever limited — at the cost of a few very dynamic tracks
    /// (classical, old jazz) staying a little quieter than the rest.
    var cleanBoostsOnly = false

    init(enabled: Bool = true, mode: Mode = .track,
         targetLUFS: Double = Level.normal.targetLUFS, cleanBoostsOnly: Bool = false) {
        self.enabled = enabled
        self.mode = mode
        self.targetLUFS = Self.snap(targetLUFS)
        self.cleanBoostsOnly = cleanBoostsOnly
    }

    /// The named level the target sits on, if any.
    var preset: Level? {
        Level.allCases.first { abs($0.targetLUFS - targetLUFS) < 0.01 }
    }

    /// Clamps to the slider range and rounds to its step.
    static func snap(_ value: Double) -> Double {
        guard value.isFinite else { return Level.normal.targetLUFS }
        let clamped = min(targetRange.upperBound, max(targetRange.lowerBound, value))
        return (clamped / targetStep).rounded() * targetStep
    }

    // MARK: Codable — reads settings saved before the slider (`level`).

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, targetLUFS, level, cleanBoostsOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .track
        cleanBoostsOnly = try c.decodeIfPresent(Bool.self, forKey: .cleanBoostsOnly) ?? false
        if let target = try? c.decodeIfPresent(Double.self, forKey: .targetLUFS) {
            targetLUFS = Self.snap(target)
        } else if let level = try? c.decodeIfPresent(Level.self, forKey: .level) {
            targetLUFS = level.targetLUFS
        } else {
            targetLUFS = Level.normal.targetLUFS
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(mode, forKey: .mode)
        try c.encode(targetLUFS, forKey: .targetLUFS)
        try c.encode(cleanBoostsOnly, forKey: .cleanBoostsOnly)
    }
}

/// Where a track's loudness figure came from.
nonisolated enum LoudnessSource: String, Equatable {
    case measuredTrack
    case measuredAlbum
    case replayGainTrack
    case replayGainAlbum

    var displayName: String {
        switch self {
        case .measuredTrack: return "measured by Aria"
        case .measuredAlbum: return "album, measured by Aria"
        case .replayGainTrack: return "ReplayGain tag"
        case .replayGainAlbum: return "ReplayGain album tag"
        }
    }
}

/// ReplayGain values read from a file's tags.
nonisolated struct ReplayGainInfo: Equatable {
    var trackGainDB: Double?
    /// Linear sample peak (1.0 = full scale).
    var trackPeak: Double?
    var albumGainDB: Double?
    var albumPeak: Double?

    var isEmpty: Bool { trackGainDB == nil && albumGainDB == nil }
}

/// A loudness figure ready to level against.
nonisolated struct LoudnessReading: Equatable {
    var lufs: Double
    var peakDBFS: Double?
    var source: LoudnessSource
}

/// The gain chosen for one track, plus enough context to explain it.
nonisolated struct LevelingDecision: Equatable {
    var gainDB: Double
    /// nil when the track's loudness isn't known yet (gain is then 0 dB).
    var reading: LoudnessReading?
    /// True when the boost was reduced to keep peaks clean.
    var limitedByPeaks: Bool
    /// True when, at this gain, the safety limiter may catch some peaks.
    var limiterMayAct: Bool

    static let unknown = LevelingDecision(gainDB: 0, reading: nil, limitedByPeaks: false, limiterMayAct: false)
}

/// What the audio tap needs: one gain and whether the safety limiter runs.
nonisolated struct LevelingConfig: Equatable {
    var gainDB: Double
    /// Catches any sample that would exceed full scale after the gain (and
    /// after EQ boosts). Never acts on audio that stays below 0 dBFS.
    var limiter: Bool

    var isActive: Bool { gainDB != 0 || limiter }

    static let off = LevelingConfig(gainDB: 0, limiter: false)
}

nonisolated enum VolumeLeveling {
    /// Largest boost applied to a quiet track, dB.
    static let maxBoostDB = 12.0
    /// Largest cut applied to a loud track, dB.
    static let maxCutDB = -24.0
    /// Peak level boosts stay under in clean mode, dBFS — headroom for
    /// inter-sample peaks and EQ.
    static let cleanCeilingDBFS = -1.0
    /// ReplayGain 2.0 reference loudness: a tag's gain brings a track to this.
    static let replayGainReferenceLUFS = -18.0

    /// Loudness implied by a ReplayGain gain tag.
    static func lufs(fromReplayGain gainDB: Double) -> Double {
        replayGainReferenceLUFS - gainDB
    }

    static func dbfs(fromLinearPeak peak: Double?) -> Double? {
        guard let peak, peak > 0 else { return nil }
        return 20 * log10(peak)
    }

    /// The gain for a track with this loudness under these settings.
    static func decide(_ reading: LoudnessReading?, settings: VolumeLevelingSettings) -> LevelingDecision {
        guard let reading, reading.lufs.isFinite else { return .unknown }
        let wanted = settings.targetLUFS - reading.lufs
        var gain = min(maxBoostDB, max(maxCutDB, wanted))
        var limitedByPeaks = false
        var limiterMayAct = false

        if gain > 0 {
            if let peak = reading.peakDBFS {
                if settings.cleanBoostsOnly {
                    let headroom = max(0, cleanCeilingDBFS - peak)
                    if gain > headroom {
                        gain = headroom
                        limitedByPeaks = true
                    }
                } else {
                    limiterMayAct = peak + gain > 0
                }
            } else if !settings.cleanBoostsOnly {
                // Unknown peak: a boost might exceed full scale.
                limiterMayAct = true
            } else {
                // Clean mode with no peak information: don't boost blindly.
                gain = 0
                limitedByPeaks = true
            }
        }
        if wanted > maxBoostDB { limitedByPeaks = true }
        // Round to 0.01 dB so tiny analysis differences don't cause re-ramps.
        gain = (gain * 100).rounded() / 100
        return LevelingDecision(gainDB: gain, reading: reading,
                                limitedByPeaks: limitedByPeaks, limiterMayAct: limiterMayAct)
    }

    /// Approximate album loudness from its tracks: the duration-weighted
    /// energy mean of their integrated loudness (what one BS.1770 measurement
    /// over the whole album would give, give or take gating). Peak is the
    /// loudest track's peak. Nil without at least one usable member.
    static func albumReading(_ members: [(lufs: Double, durationSeconds: Double, peakDBFS: Double)]) -> LoudnessReading? {
        let usable = members.filter { $0.lufs.isFinite && $0.durationSeconds > 0 }
        guard !usable.isEmpty else { return nil }
        let totalDuration = usable.reduce(0) { $0 + $1.durationSeconds }
        let energy = usable.reduce(0) { $0 + $1.durationSeconds * pow(10, $1.lufs / 10) }
        guard totalDuration > 0, energy > 0 else { return nil }
        let lufs = 10 * log10(energy / totalDuration)
        let peak = usable.map(\.peakDBFS).max()
        return LoudnessReading(lufs: lufs, peakDBFS: peak, source: .measuredAlbum)
    }

    /// Parses a ReplayGain gain value such as "-6.20 dB", "+1.5 dB" or "-3".
    static func parseGain(_ s: String?) -> Double? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.lowercased().hasSuffix("db") { t = String(t.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("+") { t.removeFirst() }
        t = t.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v.isFinite, abs(v) < 64 else { return nil }
        return v
    }

    /// Parses a ReplayGain peak value ("0.988525"); linear, >0.
    static func parsePeak(_ s: String?) -> Double? {
        guard let t = s?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."),
              let v = Double(t), v.isFinite, v > 0, v < 16 else { return nil }
        return v
    }
}
