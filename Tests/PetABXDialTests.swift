import AVFoundation
import UIKit
import XCTest
@testable import Aria___Music_Browser

/// Pet moods/growth, ABX statistics and clips, dial-mode navigation, dithering.
@MainActor
final class PetABXDialTests: XCTestCase {

    // MARK: - Pet

    private func freshPet() -> PetStore {
        PetStore(defaults: UserDefaults(suiteName: "PetTests-\(UUID().uuidString)")!)
    }

    func test_pet_moods() {
        let pet = freshPet()
        let t0 = Date()
        XCTAssertEqual(pet.mood(isPlaying: false, now: t0), .sleeping)
        pet.trackStarted("local:a", now: t0)
        XCTAssertEqual(pet.mood(isPlaying: true, now: t0.addingTimeInterval(1)), .excited)
        XCTAssertEqual(pet.mood(isPlaying: true, now: t0.addingTimeInterval(20)), .dancing)
        pet.trackStarted("local:a", now: t0.addingTimeInterval(30))
        XCTAssertEqual(pet.mood(isPlaying: true, now: t0.addingTimeInterval(31)), .dancing, "second play isn't new")
        pet.trackStarted("local:a", now: t0.addingTimeInterval(60))
        XCTAssertEqual(pet.mood(isPlaying: true, now: t0.addingTimeInterval(61)), .bored)
        pet.trackStarted("local:b", now: t0.addingTimeInterval(90))
        XCTAssertEqual(pet.mood(isPlaying: true, now: t0.addingTimeInterval(91)), .excited)
    }

    func test_pet_growsWithListeningDays() {
        let suite = UserDefaults(suiteName: "PetGrow-\(UUID().uuidString)")!
        let pet = PetStore(defaults: suite)
        XCTAssertEqual(pet.stage, .baby)
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 { pet.trackStarted("t\(i)", now: start.addingTimeInterval(Double(i) * day)) }
        XCTAssertEqual(pet.stage, .kid)
        for i in 3..<10 { pet.trackStarted("t\(i)", now: start.addingTimeInterval(Double(i) * day)) }
        XCTAssertEqual(pet.stage, .grown)
        XCTAssertEqual(PetStore(defaults: suite).stage, .grown, "growth persists")
    }

    // MARK: - ABX statistics

    func test_abx_pValues() {
        XCTAssertEqual(ABXStats.pValue(correct: 12, trials: 16), 0.0384, accuracy: 0.0001)
        XCTAssertEqual(ABXStats.pValue(correct: 8, trials: 16), 0.5982, accuracy: 0.0001)
        XCTAssertEqual(ABXStats.pValue(correct: 16, trials: 16), 1.0 / 65_536, accuracy: 1e-9)
        XCTAssertEqual(ABXStats.pValue(correct: 0, trials: 16), 1)
    }

    func test_abx_clipsAreAlignedAndLevelMatched() throws {
        let fs = 44_100.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abx-src-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = Int(fs * 8)
        let format = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let t = Double(i) / fs
            let v = Float(0.3 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 1_330 * t) + 0.1 * sin(2 * .pi * 4_100 * t))
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fs, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }

        let clips = try ABXClipMaker.make(source: url, start: 1, duration: 5, bitrate: 256_000)
        XCTAssertEqual(clips.original.frameLength, clips.encoded.frameLength)
        XCTAssertLessThan(abs(clips.levelCorrectionDB), 1)

        // Correlation between the two versions should be near 1 once aligned.
        let a = clips.original.floatChannelData![0], b = clips.encoded.floatChannelData![0]
        let n = Int(clips.original.frameLength)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in (n / 4)..<(3 * n / 4) {
            ab += Double(a[i]) * Double(b[i]); aa += Double(a[i] * a[i]); bb += Double(b[i] * b[i])
        }
        XCTAssertGreaterThan(ab / (aa * bb).squareRoot(), 0.98)
    }

    // MARK: - Dial navigation

    private func sampleNavigator() -> DialNavigator {
        DialNavigator(root: {
            DialMenu(title: "Root", items: [
                DialItem(title: "One", action: .perform { .stay }),
                DialItem(title: "Sub", action: .submenu {
                    DialMenu(title: "Sub", items: [
                        DialItem(title: "A", action: .perform { .message("hi") }),
                        DialItem(title: "B", action: .perform { .exit }),
                    ])
                }),
                DialItem(title: "Three", action: .perform { .stay }),
            ])
        })
    }

    private func selection(_ nav: DialNavigator) -> Int? {
        if case .menu(let m) = nav.top { return m.selection }
        return nil
    }

    func test_dial_rotateClampsAndReportsEnds() {
        let nav = sampleNavigator()
        XCTAssertFalse(nav.rotate(-1), "already at the top")
        XCTAssertTrue(nav.rotate(1))
        XCTAssertTrue(nav.rotate(5))
        XCTAssertEqual(selection(nav), 2)
        XCTAssertFalse(nav.rotate(1), "end of list")
    }

    func test_dial_submenuBackAndSelectionMemory() {
        let nav = sampleNavigator()
        nav.rotate(1)
        nav.select()
        XCTAssertEqual(nav.depth, 2)
        nav.rotate(1)
        XCTAssertTrue(nav.back())
        XCTAssertEqual(nav.depth, 1)
        XCTAssertEqual(selection(nav), 1, "parent keeps its selection")
        XCTAssertFalse(nav.back(), "nothing behind the root")
    }

    func test_dial_messagesAndExit() {
        let nav = sampleNavigator()
        nav.rotate(1)
        nav.select()               // into Sub
        nav.select()               // A → message
        if case .message(let text) = nav.top { XCTAssertEqual(text, "hi") } else { XCTFail("expected message") }
        nav.select()               // dismiss message
        XCTAssertEqual(nav.depth, 2)
        nav.rotate(1)
        nav.select()               // B → exit
        XCTAssertTrue(nav.exitRequested)
    }

    func test_dial_reloadableMenu() {
        var value = "Off"
        let menu = DialMenu(title: "Display") { [DialItem(title: "Click", detail: value, action: .perform { .refresh })] }
        XCTAssertEqual(menu.items.first?.detail, "Off")
        value = "On"
        menu.reload()
        XCTAssertEqual(menu.items.first?.detail, "On")
    }

    // MARK: - Dithering

    func test_atkinson_preservesAverageBrightness() {
        let side = 32
        let grey = [Double](repeating: 96, count: side * side)   // ~38 % grey
        let bits = Dither.atkinson(grey, width: side, height: side)
        let lit = Double(bits.filter { $0 }.count) / Double(bits.count)
        XCTAssertEqual(lit, 96.0 / 255.0, accuracy: 0.12)
    }

    func test_ditherBitmap_fromImage() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        let image = renderer.image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
            UIColor.black.setFill(); ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
        }
        let bits = try? XCTUnwrap(Dither.bitmap(from: image, side: 16))
        XCTAssertEqual(bits?.count, 256)
        XCTAssertEqual(bits?[8 * 16 + 2], true, "left half lit")
        XCTAssertEqual(bits?[8 * 16 + 13], false, "right half dark")
    }
}
