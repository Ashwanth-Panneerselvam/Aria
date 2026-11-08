import AVFoundation
import Combine
import SwiftUI

/// Two quiet lines of technical facts at the foot of the player:
///
///     FLAC · 16-bit · 44.1 kHz              ← source file (header facts)
///     EQ Chu II · USB DAC · 48 kHz out      ← processing + session output
///
/// The two lines are kept apart on purpose. The first describes the file; the
/// second what Aria does to it and what rate the iOS audio session is running
/// at. Nothing here claims bit-perfect output, and the DAC's own word length
/// is never shown (iOS doesn't expose it). Unknown values are omitted rather
/// than guessed. No timers: it updates on track change, EQ change, speed
/// change and audio-route change notifications only.
struct AudioInfoStrip: View {
    let track: Track
    let tokens: DesignTokens

    @EnvironmentObject private var eqController: EQController
    @EnvironmentObject private var playerManager: PlayerManager

    @State private var source: AudioSourceInfo?
    @State private var route = OutputRouteInfo.current()

    var body: some View {
        VStack(spacing: 3) {
            if let source {
                Text(source.summary)
                    .foregroundColor(tokens.textSecondary)
            }
            Text(processingLine)
                .foregroundColor(tokens.isOLED ? tokens.textDisabled : tokens.textSecondary.opacity(0.8))
        }
        .font(DS.Typography.micro.monospacedDigit())
        .tracking(0.6)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: track.id) {
            // Clear first so the previous track's specs never linger while
            // the next header is read.
            source = nil
            let info = await AudioSourceInfo.load(for: track)
            guard !Task.isCancelled else { return }
            source = info
        }
        // The session's rate can change when a track starts (Aria requests the
        // source's rate family — see `OutputSampleRate`) without a route
        // change, so re-read it when playback state settles.
        .onChange(of: playerManager.playbackState) { _ in
            route = OutputRouteInfo.current()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in
            route = OutputRouteInfo.current()
        }
    }

    // MARK: - Lines

    private var eqLabel: String {
        if let preset = eqController.parametric { return "EQ \(preset.name)" }
        return eqController.isEnabled ? "EQ Graphic" : "EQ Off"
    }

    private var processingLine: String {
        var parts = [eqLabel]
        if playerManager.playbackRate != PlaybackTuning.defaultSpeed
            || playerManager.playbackPitch != PlaybackTuning.defaultPitch {
            parts.append("Tuned")
        }
        if let name = route.label { parts.append(name) }
        if let rate = route.sampleRate, let text = AudioSourceInfo.formatSampleRate(rate) {
            parts.append("\(text) out")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let source { parts.append("Source: \(source.spokenSummary)") }
        parts.append(processingLine
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "kHz", with: "kilohertz"))
        return parts.joined(separator: ". ")
    }
}

/// What the current audio session reports about its output. This is session
/// configuration, not a measurement of the DAC.
struct OutputRouteInfo: Equatable {
    let label: String?
    let sampleRate: Double?

    static func current() -> OutputRouteInfo {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first
        let rate = session.sampleRate
        return OutputRouteInfo(label: port.map { label(for: $0) },
                               sampleRate: rate > 0 ? rate : nil)
    }

    private static func label(for port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .usbAudio:            return "USB DAC"
        case .headphones:          return "Wired"
        case .lineOut:             return "Line Out"
        case .builtInSpeaker:      return "Speaker"
        case .builtInReceiver:     return "Receiver"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "Bluetooth"
        case .airPlay:             return "AirPlay"
        case .HDMI:                return "HDMI"
        case .carAudio:            return "CarPlay"
        default:                   return port.portName
        }
    }
}
