import AVFoundation
import XCTest
@testable import Aria___Music_Browser

/// Post-EQ stage: biquad designs, bs2b crossfeed, settings → config.
@MainActor
final class DAPProcessingTests: XCTestCase {

    // MARK: - Biquad

    func test_peakFilter_hitsGainAtCentreAndIsFlatFarAway() {
        let c = Biquad.design(.peak, frequency: 1_000, gainDB: 6, q: 1, sampleRate: 48_000)
        XCTAssertEqual(c.magnitudeDB(at: 1_000, sampleRate: 48_000), 6, accuracy: 0.05)
        XCTAssertEqual(c.magnitudeDB(at: 20, sampleRate: 48_000), 0, accuracy: 0.2)
        XCTAssertEqual(c.magnitudeDB(at: 18_000, sampleRate: 48_000), 0, accuracy: 0.3)
    }

    func test_shelves_reachTheirGainInTheShelf() {
        let low = Biquad.design(.lowShelf, frequency: 105, gainDB: 6, q: 0.7, sampleRate: 44_100)
        XCTAssertEqual(low.magnitudeDB(at: 20, sampleRate: 44_100), 6, accuracy: 0.3)
        XCTAssertEqual(low.magnitudeDB(at: 5_000, sampleRate: 44_100), 0, accuracy: 0.1)
        let high = Biquad.design(.highShelf, frequency: 8_000, gainDB: -4, q: 0.7, sampleRate: 44_100)
        XCTAssertEqual(high.magnitudeDB(at: 19_000, sampleRate: 44_100), -4, accuracy: 0.4)
        XCTAssertEqual(high.magnitudeDB(at: 200, sampleRate: 44_100), 0, accuracy: 0.1)
    }

    // MARK: - Crossfeed

    /// bs2b is normalised so a centred (mono) signal keeps unity gain at DC.
    func test_crossfeed_keepsMonoAtUnity() {
        let c = DAPProcessor.crossfeedCoefficients(cutoffHz: 700, feedDB: 6, sampleRate: 48_000)
        var loL = 0.0, loR = 0.0, hiL = 0.0, hiR = 0.0, asisL = 0.0, asisR = 0.0
        var outL = 0.0
        for _ in 0..<48_000 {
            let l = 1.0, r = 1.0
            loL = c.a0Lo * l + c.b1Lo * loL
            loR = c.a0Lo * r + c.b1Lo * loR
            hiL = c.a0Hi * l + c.a1Hi * asisL + c.b1Hi * hiL
            hiR = c.a0Hi * r + c.a1Hi * asisR + c.b1Hi * hiR
            asisL = l; asisR = r
            outL = (hiL + loR) * c.gain
        }
        XCTAssertEqual(outL, 1, accuracy: 0.01)
    }

    func test_processor_crossfeedLeaksLeftIntoRight() {
        let buffer = makeBuffer(frames: 4_096) { _, ch in ch == 0 ? 0.5 : 0 }
        let p = DAPProcessor()
        p.prepare(format: buffer.format.streamDescription.pointee)
        p.update(DAPConfig(preGainDB: 0, filters: [], crossfeed: DAPConfig.Crossfeed(cutoffHz: 700, feedDB: 4.5)))
        p.process(buffer.mutableAudioBufferList, frames: Int(buffer.frameLength))
        let right = buffer.floatChannelData![1][4_000]
        XCTAssertGreaterThan(right, 0.05, "low-passed left should reach the right channel")
    }

    func test_processor_inactiveConfigLeavesAudioUntouched() {
        let buffer = makeBuffer(frames: 1_024) { i, _ in Float(sin(Double(i) * 0.05)) * 0.3 }
        let before = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 1_024))
        let p = DAPProcessor()
        p.prepare(format: buffer.format.streamDescription.pointee)
        p.update(.off)
        p.process(buffer.mutableAudioBufferList, frames: 1_024)
        let after = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 1_024))
        XCTAssertEqual(before, after)
    }

    func test_processor_bassShelfBoostsLowSine() {
        let fs = 48_000.0
        let frames = 24_000
        let buffer = makeBuffer(frames: frames, sampleRate: fs) { i, _ in
            Float(sin(2 * Double.pi * 40 * Double(i) / fs)) * 0.25
        }
        let p = DAPProcessor()
        p.prepare(format: buffer.format.streamDescription.pointee)
        p.update(DAPConfig(preGainDB: 0, filters: [DAPConfig.Filter(kind: .lowShelf, frequency: 105, gainDB: 6, q: 0.7)]))
        p.process(buffer.mutableAudioBufferList, frames: frames)
        let tail = UnsafeBufferPointer(start: buffer.floatChannelData![0] + frames / 2, count: frames / 2)
        let peak = tail.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.25 * 1.7, "≈ +5.5 dB at 40 Hz")
        XCTAssertLessThan(peak, 0.25 * 2.1)
    }

    // MARK: - Settings → config

    func test_flatSettings_produceNoProcessing() {
        let s = SoundProcessingSettings()
        XCTAssertTrue(s.allFilters.isEmpty)
        XCTAssertEqual(s.headroomDB, 0)
        XCTAssertFalse(s.makeConfig().isActive)
    }

    func test_boost_addsMatchingHeadroom() {
        var s = SoundProcessingSettings()
        s.bassDB = 6
        XCTAssertEqual(s.headroomDB, -6, accuracy: 0.4)
        XCTAssertTrue(s.makeConfig().isActive)
    }

    func test_crossfeedPresets() {
        var s = SoundProcessingSettings()
        s.crossfeed = .natural
        XCTAssertEqual(s.makeConfig().crossfeed, DAPConfig.Crossfeed(cutoffHz: 700, feedDB: 6))
        s.crossfeed = .off
        XCTAssertNil(s.makeConfig().crossfeed)
    }

    func test_hearing_typicalProfileNeedsNoCorrection() {
        let ref = -60.0
        let points = HearingProfile.testFrequencies.map { f in
            HearingPoint(frequency: f, thresholdDBFS: ref + (HearingProfile.typicalRelativeThreshold[f] ?? 0))
        }
        var s = SoundProcessingSettings()
        s.hearing = HearingProfile(points: points, measuredAt: Date())
        XCTAssertTrue(s.hearingFilters.isEmpty)
    }

    func test_hearing_lessSensitiveAt4kGetsHalfCorrection() {
        let ref = -60.0
        let points = HearingProfile.testFrequencies.map { f -> HearingPoint in
            var t = ref + (HearingProfile.typicalRelativeThreshold[f] ?? 0)
            if f == 4_000 { t += 10 }
            return HearingPoint(frequency: f, thresholdDBFS: t)
        }
        var s = SoundProcessingSettings()
        s.hearing = HearingProfile(points: points, measuredAt: Date())
        s.hearingStrength = 0.5
        let filters = s.hearingFilters
        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(filters.first?.frequency, 4_000)
        XCTAssertEqual(filters.first?.gainDB ?? 0, 5, accuracy: 0.001)

        s.hearingStrength = 1
        XCTAssertEqual(s.hearingFilters.first?.gainDB ?? 0, 6, accuracy: 0.001, "capped at +6 dB")
    }

    func test_settings_roundTripThroughManager() {
        let suite = UserDefaults(suiteName: "DAPProcessingTests-\(UUID().uuidString)")!
        let manager = SoundProcessingManager(defaults: suite)
        manager.settings.crossfeed = .gentle
        manager.settings.trebleDB = -2
        let reloaded = SoundProcessingManager(defaults: suite)
        XCTAssertEqual(reloaded.settings.crossfeed, .gentle)
        XCTAssertEqual(reloaded.settings.trebleDB, -2)
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
