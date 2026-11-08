import Foundation

/// Facts measured from a track's decoded audio, computed once and cached by
/// `LibraryAnalysisManager` in its own file (`track_analysis.json`) — the
/// library database itself is never touched.
///
/// Everything here is measured, not inferred from tags. The quality hints in
/// `QualityHint` are *heuristics* on top of these measurements and are worded
/// as such in the UI.
nonisolated struct TrackAnalysis: Codable, Equatable {
    /// Bump when the analysis algorithm changes so stale entries re-run.
    static let currentVersion = 1

    var version: Int
    /// File size at analysis time; a different size means the file changed.
    var fileSize: Int64
    var sampleRate: Double
    var channels: Int
    var durationSeconds: Double

    /// Loudness envelope for the waveform seek bar: one byte per bucket,
    /// 0 = silent … 255 = loudest part of this track (36 dB range).
    var waveform: Data

    /// Highest absolute sample value, dBFS (0 = full scale).
    var samplePeakDBFS: Double
    /// Runs of ≥3 consecutive full-scale samples (a clipping indicator).
    var clippedRuns: Int
    /// ITU-R BS.1770 integrated loudness (gated), LUFS.
    var integratedLUFS: Double?
    /// DR score (crest-factor method used by DR meters), rounded.
    var dynamicRange: Int?

    /// Highest frequency with real content in the averaged spectrum, Hz.
    var spectralCutoffHz: Double?
    /// True when content drops off a cliff at the cutoff (≥ 20 dB within
    /// ~1 kHz) — the signature of a lossy encoder's low-pass, as opposed to
    /// a recording's natural, gradual roll-off.
    var cutoffIsSharp: Bool
    /// For sources stored at more than 16 bits: true when every inspected
    /// sample sits on the 16-bit grid (i.e. 16-bit audio padded with zeros).
    var paddedTo16Bit: Bool?

    var features: Features

    /// Header facts captured at analysis time (from `AudioSourceInfo`).
    var codec: String? = nil
    var isLossless: Bool? = nil
    var declaredBitDepth: Int? = nil

    /// Quality hints for this file.
    var hints: [QualityHint] {
        QualityHint.hints(for: self, isLossless: isLossless ?? false, declaredBitDepth: declaredBitDepth)
    }

    /// Inputs for library radio similarity.
    nonisolated struct Features: Codable, Equatable {
        var tempoBPM: Double?
        /// 0…1 — how regular/strong the beat is.
        var pulseClarity: Double
        /// Power-weighted mean frequency (brightness), Hz.
        var spectralCentroidHz: Double
        /// Share of energy below 150 Hz.
        var bassRatio: Double
    }

    /// Waveform as 0…1 values.
    var waveformLevels: [Float] {
        waveform.map { Float($0) / 255 }
    }
}

/// Plain-language quality hints derived from an analysis plus the file's
/// declared format. Heuristics — shown as "likely"/"possibly", never verdicts.
nonisolated enum QualityHint: Equatable, Hashable {
    /// Lossless container, but the spectrum has a sharp low-pass typical of
    /// an MP3/AAC encode at roughly this cutoff.
    case likelyLossySource(cutoffKHz: Double)
    case possiblyLossySource(cutoffKHz: Double)
    /// Hi-res sample rate, but nothing above the CD band.
    case likelyUpsampled(cutoffKHz: Double)
    /// 24/32-bit file whose samples are all on the 16-bit grid.
    case paddedBitDepth(declared: Int)
    case clipping(runs: Int)

    var title: String {
        switch self {
        case .likelyLossySource: return "Likely from a lossy source"
        case .possiblyLossySource: return "Possibly from a lossy source"
        case .likelyUpsampled: return "Likely upsampled"
        case .paddedBitDepth: return "16-bit audio in a hi-res file"
        case .clipping: return "Clipping"
        }
    }

    var detail: String {
        switch self {
        case .likelyLossySource(let k):
            return String(format: "Sharp cutoff at %.1f kHz — typical of a ~128–192 kbps MP3/AAC converted to lossless.", k)
        case .possiblyLossySource(let k):
            return String(format: "Sharp cutoff at %.1f kHz — consistent with a high-bitrate lossy encode.", k)
        case .likelyUpsampled(let k):
            return String(format: "No content above %.1f kHz despite the hi-res sample rate.", k)
        case .paddedBitDepth(let bits):
            return "Declared \(bits)-bit, but every sample sits on the 16-bit grid."
        case .clipping(let runs):
            return "\(runs) clipped passages (consecutive full-scale samples)."
        }
    }

    /// Severity for sorting: higher = more worth acting on.
    var severity: Int {
        switch self {
        case .likelyLossySource: return 3
        case .likelyUpsampled, .paddedBitDepth: return 2
        case .possiblyLossySource: return 2
        case .clipping: return 1
        }
    }

    /// Derives hints. `isLossless` and `declaredBitDepth` come from the file
    /// header (`AudioSourceInfo`); lossy files get no "lossy source" hint.
    static func hints(for a: TrackAnalysis, isLossless: Bool, declaredBitDepth: Int?) -> [QualityHint] {
        var out: [QualityHint] = []
        if let cutoff = a.spectralCutoffHz {
            let kHz = cutoff / 1000
            let nyquist = a.sampleRate / 2
            if isLossless, a.cutoffIsSharp, cutoff < nyquist - 1000 {
                if cutoff < 16_500 {
                    out.append(.likelyLossySource(cutoffKHz: kHz))
                } else if cutoff < 19_600 {
                    out.append(.possiblyLossySource(cutoffKHz: kHz))
                }
            }
            if a.sampleRate > 48_000, cutoff < 24_000 {
                out.append(.likelyUpsampled(cutoffKHz: kHz))
            }
        }
        if let bits = declaredBitDepth, bits > 16, a.paddedTo16Bit == true {
            out.append(.paddedBitDepth(declared: bits))
        }
        if a.clippedRuns >= 20 {
            out.append(.clipping(runs: a.clippedRuns))
        }
        return out.sorted { $0.severity > $1.severity }
    }
}
