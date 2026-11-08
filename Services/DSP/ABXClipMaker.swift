import AVFoundation
import Foundation

/// The two versions of an excerpt an ABX test compares: the original PCM
/// and the same audio after an AAC encode/decode round trip, sample-aligned
/// and level-matched so the codec is the only difference.
nonisolated struct ABXClips {
    let original: AVAudioPCMBuffer
    let encoded: AVAudioPCMBuffer
    let sampleRate: Double
    let bitrate: Int
    /// Level correction applied to the encoded version, dB.
    let levelCorrectionDB: Double
    /// Encoder delay removed, in samples.
    let alignmentOffset: Int
}

nonisolated enum ABXClipMaker {

    enum ClipError: LocalizedError {
        case unreadable
        case unsupportedSampleRate(Double)
        case encodeFailed
        case tooShort

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read this file."
            case .unsupportedSampleRate(let r):
                return String(format: "%.1f kHz files aren't supported — pick a 44.1 or 48 kHz track.", r / 1000)
            case .encodeFailed: return "The AAC encoder couldn't process this excerpt."
            case .tooShort: return "This track is too short for the test."
            }
        }
    }

    static let maxAlignmentSearch = 4_096

    static func make(source: URL, start: TimeInterval, duration: TimeInterval = 15,
                     bitrate: Int, scratch: URL = FileManager.default.temporaryDirectory) throws -> ABXClips {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source) } catch { throw ClipError.unreadable }
        let format = file.processingFormat
        let sr = format.sampleRate
        guard sr <= 48_000 else { throw ClipError.unsupportedSampleRate(sr) }
        let total = file.length
        let frames = AVAudioFrameCount(min(Double(total), duration * sr))
        guard frames > AVAudioFrameCount(sr * 3) else { throw ClipError.tooShort }
        let startFrame = max(0, min(Int64(start * sr), total - Int64(frames)))

        guard let original = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ClipError.unreadable
        }
        file.framePosition = startFrame
        do { try file.read(into: original, frameCount: frames) } catch { throw ClipError.unreadable }
        applyEdgeFades(original, fadeFrames: Int(sr * 0.01))

        // Encode to AAC and decode back.
        let url = scratch.appendingPathComponent("abx-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: bitrate,
        ]
        do {
            let writer = try AVAudioFile(forWriting: url, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: original)
        } catch {
            throw ClipError.encodeFailed
        }
        let decodedFile: AVAudioFile
        do { decodedFile = try AVAudioFile(forReading: url) } catch { throw ClipError.encodeFailed }
        let decodedCapacity = AVAudioFrameCount(decodedFile.length) + 8_192
        guard decodedFile.processingFormat.channelCount == format.channelCount,
              let decoded = AVAudioPCMBuffer(pcmFormat: decodedFile.processingFormat,
                                             frameCapacity: decodedCapacity) else {
            throw ClipError.encodeFailed
        }
        do { try decodedFile.read(into: decoded) } catch { throw ClipError.encodeFailed }

        // Align (encoders add priming delay) and level-match.
        let offset = bestLag(reference: original, candidate: decoded)
        guard let encoded = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ClipError.encodeFailed
        }
        encoded.frameLength = frames
        let channels = Int(format.channelCount)
        let n = Int(frames)
        let decodedLength = Int(decoded.frameLength)
        for ch in 0..<channels {
            let dst = encoded.floatChannelData![ch]
            let src = decoded.floatChannelData![ch]
            for i in 0..<n {
                let j = i + offset
                dst[i] = (j >= 0 && j < decodedLength) ? src[j] : 0
            }
        }
        let gain = rms(original) / max(rms(encoded), 1e-12)
        for ch in 0..<channels {
            let dst = encoded.floatChannelData![ch]
            for i in 0..<n { dst[i] *= Float(gain) }
        }
        applyEdgeFades(encoded, fadeFrames: Int(sr * 0.01))

        return ABXClips(original: original, encoded: encoded, sampleRate: sr, bitrate: bitrate,
                        levelCorrectionDB: 20 * log10(gain), alignmentOffset: offset)
    }

    /// Lag L maximising Σ ref[i]·cand[i+L] over a window from the middle.
    static func bestLag(reference: AVAudioPCMBuffer, candidate: AVAudioPCMBuffer) -> Int {
        guard let r = reference.floatChannelData?[0], let c = candidate.floatChannelData?[0] else { return 0 }
        let rn = Int(reference.frameLength), cn = Int(candidate.frameLength)
        let window = min(16_384, rn / 2)
        let start = max(0, rn / 2 - window / 2)
        var best = 0
        var bestScore = -Double.infinity
        for lag in -maxAlignmentSearch...maxAlignmentSearch {
            var s = 0.0
            for i in start..<(start + window) {
                let j = i + lag
                if j < 0 || j >= cn { continue }
                s += Double(r[i]) * Double(c[j])
            }
            if s > bestScore { bestScore = s; best = lag }
        }
        return best
    }

    static func rms(_ b: AVAudioPCMBuffer) -> Double {
        guard let data = b.floatChannelData else { return 0 }
        let n = Int(b.frameLength)
        var sum = 0.0
        for ch in 0..<Int(b.format.channelCount) {
            for i in 0..<n { let v = Double(data[ch][i]); sum += v * v }
        }
        let count = Double(n * Int(b.format.channelCount))
        return count > 0 ? (sum / count).squareRoot() : 0
    }

    /// 10 ms fades so the loop point never clicks.
    static func applyEdgeFades(_ b: AVAudioPCMBuffer, fadeFrames: Int) {
        guard let data = b.floatChannelData else { return }
        let n = Int(b.frameLength)
        let f = min(fadeFrames, n / 2)
        guard f > 0 else { return }
        for ch in 0..<Int(b.format.channelCount) {
            for i in 0..<f {
                let g = Float(i) / Float(f)
                data[ch][i] *= g
                data[ch][n - 1 - i] *= g
            }
        }
    }

    /// Copy of `b` from `frame` to the end, with a short fade-in.
    static func slice(_ b: AVAudioPCMBuffer, from frame: Int) -> AVAudioPCMBuffer? {
        let n = Int(b.frameLength)
        let start = max(0, min(frame, n - 1))
        let length = n - start
        guard length > 0, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(length)),
              let src = b.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(length)
        let fade = min(256, length)
        for ch in 0..<Int(b.format.channelCount) {
            for i in 0..<length { dst[ch][i] = src[ch][start + i] }
            for i in 0..<fade { dst[ch][i] *= Float(i) / Float(fade) }
        }
        return out
    }
}

/// Statistics for an ABX run.
nonisolated enum ABXStats {
    /// One-sided binomial p-value: chance of ≥ `correct` right out of
    /// `trials` by pure guessing.
    static func pValue(correct: Int, trials: Int) -> Double {
        guard trials > 0, correct > 0 else { return 1 }
        guard correct <= trials else { return 0 }
        var p = 0.0
        for k in correct...trials {
            p += binomial(trials, k)
        }
        return p / pow(2, Double(trials))
    }

    static func binomial(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return 0 }
        var result = 1.0
        let kk = min(k, n - k)
        if kk == 0 { return 1 }
        for i in 1...kk {
            result = result * Double(n - kk + i) / Double(i)
        }
        return result
    }
}
