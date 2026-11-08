import AVFoundation
import XCTest
@testable import Aria___Music_Browser

/// Analyzer measurements on synthesized files with known properties.
@MainActor
final class TrackAnalyzerTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    func test_sine_peakLoudnessAndDR() throws {
        let fs = 44_100.0
        let url = try writeWAV(seconds: 10, sampleRate: fs) { i, _ in
            Float(0.5 * sin(2 * Double.pi * 997 * Double(i) / fs))
        }
        let a = try TrackAnalyzer.analyze(fileURL: url, declaredBitDepth: 16)
        XCTAssertEqual(a.samplePeakDBFS, -6.02, accuracy: 0.1)
        // Stereo 997 Hz at -6 dBFS: ≈ -6 LUFS (K-weighting ≈ +0.7 dB at 1 kHz).
        XCTAssertEqual(a.integratedLUFS ?? 0, -6.0, accuracy: 0.6)
        XCTAssertEqual(a.dynamicRange, 0, "a pure sine has no crest beyond its RMS reference")
        XCTAssertEqual(a.durationSeconds, 10, accuracy: 0.01)
        XCTAssertEqual(a.waveform.count, TrackAnalyzer.waveformBuckets)
        XCTAssertEqual(a.clippedRuns, 0)
    }

    func test_bandLimitedSignal_isFlaggedAsLikelyLossySource() throws {
        let fs = 44_100.0
        var rng = SeededGenerator(seed: 7)
        // Partials every 250 Hz from 250 Hz to 15.5 kHz, random phases, and
        // nothing above — what an MP3 encoder's low-pass leaves behind.
        let partials: [(f: Double, phase: Double)] = (1...62).map { k in
            (Double(k) * 250, Double.random(in: 0...6.28, using: &rng))
        }
        let url = try writeWAV(seconds: 6, sampleRate: fs) { i, _ in
            var v = 0.0
            let t = Double(i) / fs
            for p in partials { v += sin(2 * Double.pi * p.f * t + p.phase) }
            return Float(v / 62 * 0.8)
        }
        var a = try TrackAnalyzer.analyze(fileURL: url, declaredBitDepth: 16)
        let cutoff = try XCTUnwrap(a.spectralCutoffHz)
        XCTAssertEqual(cutoff, 15_600, accuracy: 400)
        XCTAssertTrue(a.cutoffIsSharp)
        a.isLossless = true
        XCTAssertTrue(a.hints.contains { if case .likelyLossySource = $0 { return true }; return false })
    }

    func test_fullBandNoise_isNotFlagged() throws {
        var rng = SeededGenerator(seed: 3)
        let url = try writeWAV(seconds: 6, sampleRate: 44_100) { _, _ in
            Float.random(in: -0.4...0.4, using: &rng)
        }
        var a = try TrackAnalyzer.analyze(fileURL: url, declaredBitDepth: 16)
        a.isLossless = true
        XCTAssertGreaterThan(a.spectralCutoffHz ?? 0, 20_000)
        XCTAssertFalse(a.hints.contains { if case .likelyLossySource = $0 { return true }; return false })
    }

    /// 16-bit samples declared as 24-bit sit on the 16-bit grid.
    func test_paddedBitDepth_detected() throws {
        var rng = SeededGenerator(seed: 11)
        let url = try writeWAV(seconds: 2, sampleRate: 44_100) { _, _ in
            Float.random(in: -0.5...0.5, using: &rng)
        }
        let a = try TrackAnalyzer.analyze(fileURL: url, declaredBitDepth: 24)
        XCTAssertEqual(a.paddedTo16Bit, true)
        XCTAssertTrue(QualityHint.hints(for: a, isLossless: true, declaredBitDepth: 24)
            .contains(.paddedBitDepth(declared: 24)))
    }

    func test_clickTrack_tempoNear120() throws {
        let fs = 44_100.0
        let period = Int(fs * 0.5) // 120 BPM
        let url = try writeWAV(seconds: 20, sampleRate: fs) { i, _ in
            let k = i % period
            return k < 400 ? Float(0.8 * sin(Double(k) * 0.3) * exp(-Double(k) / 80)) : 0
        }
        let a = try TrackAnalyzer.analyze(fileURL: url, declaredBitDepth: 16)
        let bpm = try XCTUnwrap(a.features.tempoBPM)
        XCTAssertEqual(bpm, 120, accuracy: 4)
        XCTAssertGreaterThan(a.features.pulseClarity, 0.2)
    }

    func test_unreadableFile_throws() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).flac")
        XCTAssertThrowsError(try TrackAnalyzer.analyze(fileURL: url, declaredBitDepth: nil))
    }

    func test_loudnessGating_ignoresSilence() {
        // 10 s at a steady level, then 10 s of near-silence: gating keeps the
        // integrated value at the loud part's level.
        let loud = Array(repeating: 0.01, count: 100)
        let silent = Array(repeating: 1e-12, count: 100)
        let both = LoudnessMath.integratedLUFS(subBlockEnergies: loud + silent)
        let loudOnly = LoudnessMath.integratedLUFS(subBlockEnergies: loud)
        XCTAssertEqual(both ?? 0, loudOnly ?? 1, accuracy: 0.2)
    }

    // MARK: - Helpers

    /// Writes a 16-bit stereo WAV from a sample function and returns its URL.
    private func writeWAV(seconds: Double, sampleRate: Double,
                          _ sample: (Int, Int) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-\(UUID().uuidString).wav")
        tempFiles.append(url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let frames = Int(seconds * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            for ch in 0..<2 { buffer.floatChannelData![ch][i] = sample(i, ch) }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } // file closes when it goes out of scope
        return url
    }
}

/// Deterministic RNG for repeatable tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
