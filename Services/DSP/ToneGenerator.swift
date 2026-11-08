import AVFoundation
import Foundation

/// Shared between the UI and the render callback. Plain stored properties:
/// a torn read only shifts a pulse or level by one buffer.
nonisolated final class ToneState {
    var frequency = 1_000.0
    var sampleRate = 48_000.0
    var amplitude = 0.0
    var targetAmplitude = 0.0
    var phase = 0.0
    var counter = 0
}

/// Pulsed sine tones (0.4 s on / 0.3 s off, 20 ms ramps) for the hearing
/// check, played through a dedicated `AVAudioEngine` — so the check hears
/// the IEMs as they are, without the EQ or processing stages.
final class ToneGenerator {
    private let engine = AVAudioEngine()
    private let state = ToneState()
    private var source: AVAudioSourceNode?

    enum ToneError: Error { case noFormat }

    func start() throws {
        try AVAudioSession.sharedInstance().setActive(true)
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = hardwareRate > 0 ? hardwareRate : 48_000
        state.sampleRate = rate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw ToneError.noFormat
        }
        let node = Self.makeSourceNode(state: state)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        try engine.start()
        source = node
    }

    func stop() {
        state.targetAmplitude = 0
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
    }

    /// Starts (or continues) pulsing `frequency` at `levelDBFS`.
    func play(frequency: Double, levelDBFS: Double, restartPulse: Bool) {
        state.frequency = frequency
        state.targetAmplitude = pow(10, levelDBFS / 20)
        if restartPulse { state.counter = 0 }
    }

    func mute() { state.targetAmplitude = 0 }

    /// Built outside the main actor: the render block runs on the audio thread.
    nonisolated static func makeSourceNode(state: ToneState) -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let sr = state.sampleRate
            let period = max(1, Int(sr * 0.7))
            let onLength = Int(sr * 0.4)
            let ramp = max(1, Int(sr * 0.02))
            let twoPi = 2 * Double.pi
            for frame in 0..<Int(frameCount) {
                state.amplitude += (state.targetAmplitude - state.amplitude) * 0.0015
                let pos = state.counter % period
                var envelope = 0.0
                if pos < onLength {
                    if pos < ramp {
                        envelope = Double(pos) / Double(ramp)
                    } else if pos > onLength - ramp {
                        envelope = Double(onLength - pos) / Double(ramp)
                    } else {
                        envelope = 1
                    }
                }
                let value = Float(sin(state.phase) * state.amplitude * envelope)
                state.phase += twoPi * state.frequency / sr
                if state.phase > twoPi { state.phase -= twoPi }
                state.counter += 1
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
    }
}
