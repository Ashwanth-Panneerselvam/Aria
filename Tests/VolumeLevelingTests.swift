import AVFoundation
import XCTest
@testable import Aria___Music_Browser

/// Volume leveling: gain decisions, album loudness, tag parsing, and the
/// real-time gain + safety limiter.
@MainActor
final class VolumeLevelingTests: XCTestCase {

    private func reading(_ lufs: Double, peak: Double? = -0.1) -> LoudnessReading {
        LoudnessReading(lufs: lufs, peakDBFS: peak, source: .measuredTrack)
    }

    // MARK: - Decisions

    func test_loudTrack_isTurnedDownToTarget() {
        let d = VolumeLeveling.decide(reading(-8), settings: VolumeLevelingSettings())
        XCTAssertEqual(d.gainDB, -8, accuracy: 0.001, "−16 target − (−8)")
        XCTAssertFalse(d.limiterMayAct)
        XCTAssertFalse(d.limitedByPeaks)
    }

    func test_twoTracksEndUpAtTheSameLoudness() {
        let s = VolumeLevelingSettings()
        for lufs in [-6.5, -9.0, -14.2, -20.0] {
            let d = VolumeLeveling.decide(reading(lufs, peak: -12), settings: s)
            XCTAssertEqual(lufs + d.gainDB, s.level.targetLUFS, accuracy: 0.01)
        }
    }

    func test_quietTrackWithHighPeaks_fullBoostFlagsLimiter() {
        let d = VolumeLeveling.decide(reading(-20, peak: -0.5), settings: VolumeLevelingSettings())
        XCTAssertEqual(d.gainDB, 4, accuracy: 0.001)
        XCTAssertTrue(d.limiterMayAct)
    }

    func test_quietTrackWithHighPeaks_cleanModeCapsBoost() {
        var s = VolumeLevelingSettings()
        s.cleanBoostsOnly = true
        let d = VolumeLeveling.decide(reading(-20, peak: -3), settings: s)
        XCTAssertEqual(d.gainDB, 2, accuracy: 0.001, "−3 dBFS peak may rise to −1 dBFS")
        XCTAssertTrue(d.limitedByPeaks)
        XCTAssertFalse(d.limiterMayAct)
    }

    func test_cleanMode_neverCutsJustBecauseOfPeaks() {
        var s = VolumeLevelingSettings()
        s.cleanBoostsOnly = true
        let d = VolumeLeveling.decide(reading(-18, peak: 0), settings: s)
        XCTAssertEqual(d.gainDB, 0, accuracy: 0.001)
    }

    func test_boostIsCapped() {
        let d = VolumeLeveling.decide(reading(-40, peak: -30), settings: VolumeLevelingSettings())
        XCTAssertEqual(d.gainDB, VolumeLeveling.maxBoostDB, accuracy: 0.001)
        XCTAssertTrue(d.limitedByPeaks)
    }

    func test_unknownLoudness_isZeroGain() {
        XCTAssertEqual(VolumeLeveling.decide(nil, settings: VolumeLevelingSettings()), .unknown)
    }

    func test_levels() {
        var s = VolumeLevelingSettings()
        s.level = .loud
        XCTAssertEqual(VolumeLeveling.decide(reading(-10), settings: s).gainDB, -4, accuracy: 0.001)
        s.level = .quiet
        XCTAssertEqual(VolumeLeveling.decide(reading(-10), settings: s).gainDB, -8, accuracy: 0.001)
    }

    // MARK: - ReplayGain and album

    func test_replayGainConversion() {
        // A track tagged −6 dB is 6 dB louder than the −18 LUFS reference.
        XCTAssertEqual(VolumeLeveling.lufs(fromReplayGain: -6), -12, accuracy: 1e-9)
        XCTAssertEqual(VolumeLeveling.dbfs(fromLinearPeak: 0.5) ?? 0, -6.0206, accuracy: 0.001)
        XCTAssertNil(VolumeLeveling.dbfs(fromLinearPeak: 0))
    }

    func test_parseGainAndPeak() {
        XCTAssertEqual(VolumeLeveling.parseGain("-6.20 dB"), -6.2)
        XCTAssertEqual(VolumeLeveling.parseGain("+1.5 dB"), 1.5)
        XCTAssertEqual(VolumeLeveling.parseGain("-3"), -3)
        XCTAssertEqual(VolumeLeveling.parseGain("-2,5 dB"), -2.5)
        XCTAssertNil(VolumeLeveling.parseGain("loud"))
        XCTAssertNil(VolumeLeveling.parseGain(""))
        XCTAssertEqual(VolumeLeveling.parsePeak("0.988525"), 0.988525)
        XCTAssertNil(VolumeLeveling.parsePeak("0"))
    }

    func test_albumReading_isEnergyMeanWeightedByDuration() throws {
        // Two equal-length tracks 10 dB apart: energy mean ≈ louder − 2.6 dB.
        let r = try XCTUnwrap(VolumeLeveling.albumReading([
            (lufs: -10, durationSeconds: 200, peakDBFS: -0.2),
            (lufs: -20, durationSeconds: 200, peakDBFS: -6),
        ]))
        XCTAssertEqual(r.lufs, 10 * log10((pow(10, -1.0) + pow(10, -2.0)) / 2), accuracy: 1e-9)
        XCTAssertEqual(r.peakDBFS, -0.2)
        XCTAssertEqual(r.source, .measuredAlbum)
        // Identical tracks → same loudness.
        let same = try XCTUnwrap(VolumeLeveling.albumReading([
            (lufs: -12, durationSeconds: 100, peakDBFS: -1), (lufs: -12, durationSeconds: 300, peakDBFS: -1),
        ]))
        XCTAssertEqual(same.lufs, -12, accuracy: 1e-9)
        XCTAssertNil(VolumeLeveling.albumReading([]))
    }

    // MARK: - Settings

    func test_defaults_areOnTrackNormal() {
        let s = VolumeLevelingSettings()
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.mode, .track)
        XCTAssertEqual(s.level.targetLUFS, -16)
        XCTAssertFalse(s.cleanBoostsOnly)
    }

    func test_settings_roundTripThroughManager() {
        let suite = UserDefaults(suiteName: "VolumeLevelingTests-\(UUID().uuidString)")!
        let manager = VolumeLevelingManager(defaults: suite)
        manager.settings.mode = .album
        manager.settings.level = .quiet
        let reloaded = VolumeLevelingManager(defaults: suite)
        XCTAssertEqual(reloaded.settings.mode, .album)
        XCTAssertEqual(reloaded.settings.level, .quiet)
    }

    func test_offConfig_isInactive() {
        XCTAssertFalse(LevelingConfig.off.isActive)
        XCTAssertTrue(LevelingConfig(gainDB: 0, limiter: true).isActive)
    }

    // MARK: - DSP

    func test_processor_appliesGainFromTheFirstSample() {
        let buffer = makeBuffer(frames: 2_048) { i, _ in Float(sin(Double(i) * 0.05)) * 0.5 }
        let before = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 2_048))
        let p = DAPProcessor()
        p.updateLeveling(LevelingConfig(gainDB: -6.0206, limiter: true))
        p.prepare(format: buffer.format.streamDescription.pointee)
        p.process(buffer.mutableAudioBufferList, frames: 2_048)
        let after = buffer.floatChannelData![0]
        for i in [1, 100, 2_000] {
            XCTAssertEqual(after[i], before[i] * 0.5, accuracy: 1e-4)
        }
    }

    func test_processor_limiterKeepsBoostedPeaksAtFullScale() {
        let fs = 44_100.0
        let frames = 22_050
        let buffer = makeBuffer(frames: frames, sampleRate: fs) { i, _ in
            Float(sin(2 * Double.pi * 100 * Double(i) / fs)) * 0.9
        }
        let p = DAPProcessor()
        p.updateLeveling(LevelingConfig(gainDB: 6, limiter: true))
        p.prepare(format: buffer.format.streamDescription.pointee)
        p.process(buffer.mutableAudioBufferList, frames: frames)
        let peak = (0..<frames).map { abs(buffer.floatChannelData![1][$0]) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 1.0001)
        XCTAssertGreaterThan(peak, 0.99)
    }

    func test_processor_limiterLeavesQuietAudioUntouched() {
        let buffer = makeBuffer(frames: 4_096) { i, _ in Float(sin(Double(i) * 0.02)) * 0.2 }
        let before = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 4_096))
        let p = DAPProcessor()
        p.updateLeveling(LevelingConfig(gainDB: 0, limiter: true))
        p.prepare(format: buffer.format.streamDescription.pointee)
        p.process(buffer.mutableAudioBufferList, frames: 4_096)
        let after = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 4_096))
        XCTAssertEqual(before, after)
    }

    func test_processor_gainChangeMidTrackGlides() {
        let fs = 44_100.0
        let p = DAPProcessor()
        let first = makeBuffer(frames: 1_024, sampleRate: fs) { _, _ in 0.25 }
        p.updateLeveling(LevelingConfig(gainDB: 0, limiter: true))
        p.prepare(format: first.format.streamDescription.pointee)
        p.process(first.mutableAudioBufferList, frames: 1_024)

        p.updateLeveling(LevelingConfig(gainDB: -6.0206, limiter: true))
        let frames = 88_200
        let second = makeBuffer(frames: frames, sampleRate: fs) { _, _ in 0.25 }
        p.process(second.mutableAudioBufferList, frames: frames)
        let out = second.floatChannelData![0]
        XCTAssertGreaterThan(out[10], 0.24, "no sudden jump")
        XCTAssertEqual(out[frames - 1], 0.125, accuracy: 0.002, "settled after 2 s")
    }

    // MARK: - Helpers

    private func makeBuffer(frames: Int, sampleRate: Double = 44_100,
                            _ sample: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            for i in 0..<frames { buffer.floatChannelData![ch][i] = sample(i, ch) }
        }
        return buffer
    }
}
