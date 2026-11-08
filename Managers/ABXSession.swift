import AVFoundation
import Combine
import Foundation

/// Runs one ABX challenge: 16 trials, each with a fresh random X. Playback
/// uses its own `AVAudioEngine` so A, B and X take exactly the same path
/// (no EQ or processing on either), and switching keeps the playhead so you
/// can flip between them mid-phrase.
@MainActor
final class ABXSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case testing
        case finished
        case failed(String)
    }

    enum Source: String, Equatable { case a = "A", b = "B", x = "X" }

    static let totalTrials = 16

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var playing: Source?
    @Published private(set) var trial = 1
    @Published private(set) var correct = 0
    @Published private(set) var levelCorrectionDB = 0.0
    @Published private(set) var bitrate = 256_000
    @Published private(set) var trackTitle = ""

    private var clips: ABXClips?
    private var xIsA = true
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var engineReady = false
    /// Clip frame at which the currently scheduled slice began.
    private var sliceStart = 0

    var pValue: Double { ABXStats.pValue(correct: correct, trials: answered) }
    var answered: Int { phase == .finished ? Self.totalTrials : trial - 1 }

    // MARK: - Setup

    func prepare(url: URL, title: String, start: TimeInterval, bitrate: Int) {
        stopPlayback()
        phase = .preparing
        trackTitle = title
        self.bitrate = bitrate
        trial = 1
        correct = 0
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ABXClips, Error> in
                do {
                    return .success(try ABXClipMaker.make(source: url, start: start, bitrate: bitrate))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let clips):
                self.clips = clips
                self.levelCorrectionDB = clips.levelCorrectionDB
                do {
                    try self.setUpEngine(format: clips.original.format)
                    self.newTrial()
                    self.phase = .testing
                } catch {
                    self.phase = .failed("Couldn't start audio: \(error.localizedDescription)")
                }
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func setUpEngine(format: AVAudioFormat) throws {
        try AVAudioSession.sharedInstance().setActive(true)
        if !engineReady {
            engine.attach(node)
            engineReady = true
        } else {
            engine.stop()
            engine.disconnectNodeOutput(node)
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    private func newTrial() {
        xIsA = Bool.random()
    }

    // MARK: - Playback

    private func buffer(for source: Source) -> AVAudioPCMBuffer? {
        guard let clips else { return nil }
        switch source {
        case .a: return clips.original
        case .b: return clips.encoded
        case .x: return xIsA ? clips.original : clips.encoded
        }
    }

    /// Current playhead within the clip.
    private var currentFrame: Int {
        guard playing != nil, let clips,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        let total = Int(clips.original.frameLength)
        guard total > 0 else { return 0 }
        return (sliceStart + Int(max(0, playerTime.sampleTime))) % total
    }

    /// Switches to `source` at the same position (or starts from the top).
    func play(_ source: Source) {
        guard phase == .testing, let full = buffer(for: source) else { return }
        let position = playing == nil ? 0 : currentFrame
        node.stop()
        if let slice = ABXClipMaker.slice(full, from: position) {
            node.scheduleBuffer(slice, at: nil, options: [])
            node.scheduleBuffer(full, at: nil, options: .loops)
            sliceStart = position
        } else {
            node.scheduleBuffer(full, at: nil, options: .loops)
            sliceStart = 0
        }
        if !engine.isRunning { try? engine.start() }
        node.play()
        playing = source
    }

    func stopPlayback() {
        node.stop()
        playing = nil
    }

    /// Restart the current source from the beginning of the excerpt.
    func restart() {
        guard let current = playing else { return }
        node.stop()
        playing = nil
        play(current)
    }

    // MARK: - Answers

    func answer(xIsA guess: Bool) {
        guard phase == .testing else { return }
        if guess == xIsA { correct += 1 }
        Haptics.light()
        if trial >= Self.totalTrials {
            stopPlayback()
            phase = .finished
            return
        }
        trial += 1
        let wasPlaying = playing
        newTrial()
        // Keep listening if X was playing: it may now be the other version.
        if wasPlaying == .x { play(.x) }
    }

    func end() {
        stopPlayback()
        engine.stop()
        clips = nil
        phase = .idle
    }

    // MARK: - Verdict

    var verdict: (title: String, detail: String) {
        let p = pValue
        let kbps = bitrate / 1000
        if p < 0.01 {
            return ("You can hear it", "\(correct) of \(Self.totalTrials) right. That's very unlikely to be luck (p = \(Self.format(p))). \(kbps) kbps AAC isn't transparent for you on this passage.")
        } else if p < 0.05 {
            return ("You can probably hear it", "\(correct) of \(Self.totalTrials) right (p = \(Self.format(p))). Probably not luck — try again to confirm.")
        } else {
            return ("Not reliably", "\(correct) of \(Self.totalTrials) right (p = \(Self.format(p))). Could be guessing: \(kbps) kbps AAC is effectively transparent for you on this passage.")
        }
    }

    static func format(_ p: Double) -> String {
        p < 0.001 ? "< 0.001" : String(format: "%.3f", p)
    }
}
