import SwiftUI

/// Seek bar for the full-screen player.
///
/// It is the only part of the player that observes `PlaybackClock`, so the
/// 4 Hz position tick re-renders this small view instead of the whole player
/// (artwork, controls, metadata). Seeking commits once, on release — the old
/// `Slider` called `seek` on every drag frame — while the time labels follow
/// the finger live.
struct PlayerScrubber: View {
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let tokens: DesignTokens
    /// True while the track is loading or rebuffering. The bar then shows
    /// "Buffering…" instead of a remaining time, so a stalled clock never
    /// reads as normal progress.
    let isBuffering: Bool
    /// Loudness envelope (0…1) for a waveform-style bar; nil draws the slim
    /// line. Comes from `LibraryAnalysisManager` — computed once per track.
    var waveform: [Float]? = nil
    let onSeek: (TimeInterval) -> Void

    /// Fraction under the finger while dragging; nil when idle.
    @State private var dragFraction: Double?

    /// Distance a VoiceOver swipe up/down moves the playhead.
    private let accessibilityStep: TimeInterval = 10

    private var hasDuration: Bool { clock.duration > 0 }

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard hasDuration else { return 0 }
        return min(max(clock.currentTime / clock.duration, 0), 1)
    }

    private var displayedTime: TimeInterval {
        if let dragFraction, hasDuration { return dragFraction * clock.duration }
        return max(0, clock.currentTime)
    }

    var body: some View {
        VStack(spacing: 2) {
            bar
            timeRow
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(hasDuration
                            ? "\(Self.format(displayedTime)) of \(Self.format(clock.duration))"
                            : (isBuffering ? "Buffering" : "Unknown"))
        .accessibilityAdjustableAction { direction in
            guard hasDuration else { return }
            switch direction {
            case .increment:
                onSeek(min(clock.duration, clock.currentTime + accessibilityStep))
            case .decrement:
                onSeek(max(0, clock.currentTime - accessibilityStep))
            @unknown default:
                break
            }
        }
    }

    // MARK: - Bar

    private var bar: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let dragging = dragFraction != nil
            let barHeight: CGFloat = dragging ? 6 : 3
            ZStack(alignment: .leading) {
                if let waveform, !waveform.isEmpty {
                    waveformBar(waveform, width: width, height: geo.size.height, dragging: dragging)
                } else {
                    Capsule()
                        .fill(tokens.isOLED ? tokens.hairline : tokens.textPrimary.opacity(0.15))
                        .frame(height: barHeight)
                    Capsule()
                        .fill(hasDuration ? tokens.textPrimary : tokens.textDisabled)
                        .frame(width: max(barHeight, width * fraction), height: barHeight)
                    if dragging {
                        Circle()
                            .fill(tokens.textPrimary)
                            .frame(width: 14, height: 14)
                            .offset(x: width * fraction - 7)
                    }
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard hasDuration else { return }
                        let next = min(max(value.location.x / width, 0), 1)
                        if reduceMotion || dragFraction != nil {
                            dragFraction = next
                        } else {
                            withAnimation(.easeOut(duration: 0.12)) { dragFraction = next }
                        }
                    }
                    .onEnded { value in
                        guard hasDuration else { dragFraction = nil; return }
                        let committed = min(max(value.location.x / width, 0), 1)
                        onSeek(committed * clock.duration)
                        dragFraction = nil
                    }
            )
        }
        // 44 pt touch target around a 3 pt line.
        .frame(height: 44)
    }

    /// Bars for the track's loudness, played part bright, rest dim. The
    /// bar shape is built once per size; only the mask width follows the
    /// playhead.
    private func waveformBar(_ levels: [Float], width: CGFloat, height: CGFloat,
                             dragging: Bool) -> some View {
        let shape = WaveformBars(levels: levels)
        let barArea = min(height, 34)
        return ZStack(alignment: .leading) {
            shape
                .fill(tokens.isOLED ? tokens.hairline : tokens.textPrimary.opacity(0.18))
            shape
                .fill(hasDuration ? tokens.textPrimary : tokens.textDisabled)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, width * fraction))
                }
            if dragging {
                Rectangle()
                    .fill(tokens.accent)
                    .frame(width: 2, height: barArea + 6)
                    .offset(x: max(0, width * fraction - 1))
            }
        }
        .frame(width: width, height: barArea)
    }

    // MARK: - Times

    private var timeRow: some View {
        HStack {
            Text(hasDuration || clock.currentTime > 0 ? Self.format(displayedTime) : "--:--")
            Spacer(minLength: DS.Spacing.sm)
            if isBuffering {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(tokens.textSecondary)
                    Text("Buffering…")
                }
            } else {
                Text(hasDuration ? "-" + Self.format(max(0, clock.duration - displayedTime)) : "--:--")
            }
        }
        .font(DS.Typography.caption.monospacedDigit())
        .foregroundColor(dragFraction != nil ? tokens.textPrimary : tokens.textSecondary)
        .lineLimit(1)
        .padding(.top, -10) // tuck the labels under the slim bar's touch area
    }

    // MARK: - Formatting

    /// "3:07", or "1:02:45" past an hour.
    static func format(_ time: TimeInterval) -> String {
        let t = Int(max(0, time.isFinite ? time : 0))
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// Vertical bars, one per ~3 pt, heights from a 0…1 loudness envelope.
struct WaveformBars: Shape {
    let levels: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !levels.isEmpty, rect.width > 0 else { return path }
        let barCount = max(1, Int(rect.width / 3))
        let step = rect.width / CGFloat(barCount)
        let barWidth = max(1, step * 0.62)
        let n = levels.count
        for i in 0..<barCount {
            let s0 = i * n / barCount
            let s1 = max(s0 + 1, (i + 1) * n / barCount)
            var level: Float = 0
            for j in s0..<min(s1, n) { level = max(level, levels[j]) }
            let h = max(2, CGFloat(level) * rect.height)
            let r = CGRect(x: CGFloat(i) * step, y: rect.midY - h / 2, width: barWidth, height: h)
            path.addRoundedRect(in: r, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path
    }
}
