import AVFoundation
import Foundation

/// Read-only facts about a local audio *file*: codec, sample rate, source bit
/// depth, channel count — read from the container header, nothing inferred.
///
/// This describes the SOURCE only. It says nothing about what reaches the DAC:
/// iOS mixes every app at 44.1 or 48 kHz (see `OutputSampleRate` and
/// docs/design/2026-07-25-bit-perfect-dac-assessment.md), EQ and speed change
/// the samples, and the hardware word length isn't exposed. The player strip
/// therefore labels these values as source specs and shows processing and the
/// session's output rate separately.
///
/// Probing is a header read via `AVAudioFile` — it doesn't touch the playback
/// engine, and runs off the main thread (`load(for:)`).
struct AudioSourceInfo: Equatable {
    /// "FLAC", "ALAC", "WAV", "AIFF", "AAC", "MP3".
    let codec: String
    let isLossless: Bool
    let sampleRate: Double?
    /// Bits per sample of the *source*. Nil when the format doesn't carry one
    /// (lossy codecs) or the header doesn't say — never guessed.
    let bitDepth: Int?
    let channels: Int?

    /// Explicitly nonisolated so `make` can build values off the main actor
    /// (the target defaults to MainActor isolation).
    nonisolated init(codec: String, isLossless: Bool, sampleRate: Double?,
                     bitDepth: Int?, channels: Int?) {
        self.codec = codec
        self.isLossless = isLossless
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
    }

    /// "FLAC · 16-bit · 44.1 kHz". Unknown fields are omitted.
    var summary: String {
        var parts = [codec]
        if let bitDepth { parts.append("\(bitDepth)-bit") }
        if let sampleRate, let text = Self.formatSampleRate(sampleRate) { parts.append(text) }
        return parts.joined(separator: " · ")
    }

    /// Spoken form for VoiceOver.
    var spokenSummary: String {
        var parts = [codec]
        if let bitDepth { parts.append("\(bitDepth) bit") }
        if let sampleRate, let text = Self.formatSampleRate(sampleRate) {
            parts.append(text.replacingOccurrences(of: "kHz", with: "kilohertz"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Probing

    /// Reads the file header. Returns nil if the file can't be opened or the
    /// codec isn't one we can name honestly. Safe to call off the main actor.
    nonisolated static func probe(fileURL: URL) -> AudioSourceInfo? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let asbd = file.fileFormat.streamDescription.pointee
        return make(formatID: asbd.mFormatID,
                    formatFlags: asbd.mFormatFlags,
                    sampleRate: asbd.mSampleRate,
                    bitsPerChannel: asbd.mBitsPerChannel,
                    channels: asbd.mChannelsPerFrame,
                    fileExtension: fileURL.pathExtension)
    }

    /// Pure mapping from a stream description to display facts. Split out of
    /// `probe` so it can be unit-tested without audio files.
    nonisolated static func make(formatID: AudioFormatID,
                                 formatFlags: AudioFormatFlags,
                                 sampleRate: Double,
                                 bitsPerChannel: UInt32,
                                 channels: UInt32,
                                 fileExtension: String) -> AudioSourceInfo? {
        let codec: String
        let lossless: Bool
        var depth: Int?

        switch formatID {
        case kAudioFormatFLAC:
            codec = "FLAC"; lossless = true
            depth = losslessSourceBitDepth(flags: formatFlags)
        case kAudioFormatAppleLossless:
            codec = "ALAC"; lossless = true
            depth = losslessSourceBitDepth(flags: formatFlags)
        case kAudioFormatLinearPCM:
            switch fileExtension.lowercased() {
            case "wav", "wave": codec = "WAV"
            case "aif", "aiff", "aifc": codec = "AIFF"
            default: codec = "PCM"
            }
            lossless = true
            depth = bitsPerChannel > 0 ? Int(bitsPerChannel) : nil
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            codec = "AAC"; lossless = false
        case kAudioFormatMPEGLayer3:
            codec = "MP3"; lossless = false
        default:
            return nil
        }

        return AudioSourceInfo(
            codec: codec,
            isLossless: lossless,
            sampleRate: sampleRate > 0 ? sampleRate : nil,
            bitDepth: depth,
            channels: channels > 0 ? Int(channels) : nil
        )
    }

    /// FLAC and ALAC store the source word length in `mFormatFlags` using the
    /// `kAppleLosslessFormatFlag_*BitSourceData` values (1…4).
    nonisolated static func losslessSourceBitDepth(flags: AudioFormatFlags) -> Int? {
        switch flags {
        case 1: return 16
        case 2: return 20
        case 3: return 24
        case 4: return 32
        default: return nil
        }
    }

    /// 44100 → "44.1 kHz", 48000 → "48 kHz", 22050 → "22.05 kHz".
    nonisolated static func formatSampleRate(_ hz: Double) -> String? {
        guard hz.isFinite, hz > 0 else { return nil }
        let khz = (hz / 10).rounded() / 100   // two decimals
        return String(format: "%g kHz", khz)
    }

    // MARK: - Cache

    /// Header facts never change for a given file, so they are probed once
    /// per file per launch. Keyed by path; a handful of entries per session.
    private static var cache: [String: AudioSourceInfo] = [:]

    /// Cached, off-main probe of a local track. Returns nil for streamed
    /// tracks (no file to read) and for files that can't be described.
    static func load(for track: Track) async -> AudioSourceInfo? {
        guard let url = track.localFileURL else { return nil }
        let key = url.path
        if let hit = cache[key] { return hit }
        let info = await Task.detached(priority: .utility) {
            AudioSourceInfo.probe(fileURL: url)
        }.value
        if let info { cache[key] = info }
        return info
    }
}
