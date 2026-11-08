import AVFoundation
import XCTest
@testable import Aria___Music_Browser

/// The player's audio-facts strip must only show what the file header says.
@MainActor
final class AudioSourceInfoTests: XCTestCase {

    func test_sampleRateFormatting() {
        XCTAssertEqual(AudioSourceInfo.formatSampleRate(44_100), "44.1 kHz")
        XCTAssertEqual(AudioSourceInfo.formatSampleRate(48_000), "48 kHz")
        XCTAssertEqual(AudioSourceInfo.formatSampleRate(88_200), "88.2 kHz")
        XCTAssertEqual(AudioSourceInfo.formatSampleRate(96_000), "96 kHz")
        XCTAssertEqual(AudioSourceInfo.formatSampleRate(176_400), "176.4 kHz")
        XCTAssertEqual(AudioSourceInfo.formatSampleRate(22_050), "22.05 kHz")
        XCTAssertNil(AudioSourceInfo.formatSampleRate(0))
        XCTAssertNil(AudioSourceInfo.formatSampleRate(.nan))
    }

    func test_flac_readsSourceBitDepthFromFlags() {
        let info = AudioSourceInfo.make(formatID: kAudioFormatFLAC, formatFlags: 1,
                                        sampleRate: 44_100, bitsPerChannel: 0,
                                        channels: 2, fileExtension: "flac")
        XCTAssertEqual(info?.codec, "FLAC")
        XCTAssertEqual(info?.bitDepth, 16)
        XCTAssertEqual(info?.isLossless, true)
        XCTAssertEqual(info?.summary, "FLAC · 16-bit · 44.1 kHz")
    }

    func test_alac24() {
        let info = AudioSourceInfo.make(formatID: kAudioFormatAppleLossless, formatFlags: 3,
                                        sampleRate: 96_000, bitsPerChannel: 0,
                                        channels: 2, fileExtension: "m4a")
        XCTAssertEqual(info?.summary, "ALAC · 24-bit · 96 kHz")
    }

    func test_unknownLosslessFlags_omitBitDepthRatherThanGuess() {
        let info = AudioSourceInfo.make(formatID: kAudioFormatFLAC, formatFlags: 0,
                                        sampleRate: 44_100, bitsPerChannel: 0,
                                        channels: 2, fileExtension: "flac")
        XCTAssertNil(info?.bitDepth)
        XCTAssertEqual(info?.summary, "FLAC · 44.1 kHz")
    }

    func test_pcmUsesBitsPerChannelAndContainerName() {
        let wav = AudioSourceInfo.make(formatID: kAudioFormatLinearPCM, formatFlags: 0,
                                       sampleRate: 48_000, bitsPerChannel: 24,
                                       channels: 2, fileExtension: "wav")
        XCTAssertEqual(wav?.summary, "WAV · 24-bit · 48 kHz")
        let aiff = AudioSourceInfo.make(formatID: kAudioFormatLinearPCM, formatFlags: 0,
                                        sampleRate: 44_100, bitsPerChannel: 16,
                                        channels: 2, fileExtension: "AIFF")
        XCTAssertEqual(aiff?.codec, "AIFF")
    }

    /// m4a can hold AAC or ALAC; the format ID — not the extension — decides.
    func test_aacInM4A_isLossyWithNoBitDepth() {
        let info = AudioSourceInfo.make(formatID: kAudioFormatMPEG4AAC, formatFlags: 0,
                                        sampleRate: 44_100, bitsPerChannel: 0,
                                        channels: 2, fileExtension: "m4a")
        XCTAssertEqual(info?.codec, "AAC")
        XCTAssertEqual(info?.isLossless, false)
        XCTAssertNil(info?.bitDepth)
        XCTAssertEqual(info?.summary, "AAC · 44.1 kHz")
    }

    func test_mp3() {
        let info = AudioSourceInfo.make(formatID: kAudioFormatMPEGLayer3, formatFlags: 0,
                                        sampleRate: 44_100, bitsPerChannel: 0,
                                        channels: 2, fileExtension: "mp3")
        XCTAssertEqual(info?.summary, "MP3 · 44.1 kHz")
    }

    func test_unnamedCodec_returnsNil() {
        XCTAssertNil(AudioSourceInfo.make(formatID: kAudioFormatAC3, formatFlags: 0,
                                          sampleRate: 48_000, bitsPerChannel: 0,
                                          channels: 6, fileExtension: "ac3"))
    }

    func test_probe_missingFile_returnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).flac")
        XCTAssertNil(AudioSourceInfo.probe(fileURL: url))
    }

    // MARK: - Scrubber time format

    func test_scrubberTimeFormat() {
        XCTAssertEqual(PlayerScrubber.format(0), "0:00")
        XCTAssertEqual(PlayerScrubber.format(187), "3:07")
        XCTAssertEqual(PlayerScrubber.format(3765), "1:02:45")
        XCTAssertEqual(PlayerScrubber.format(-5), "0:00")
        XCTAssertEqual(PlayerScrubber.format(.nan), "0:00")
    }
}
