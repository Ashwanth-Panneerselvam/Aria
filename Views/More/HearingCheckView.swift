import SwiftUI

/// Drives the hearing check: for each test frequency a pulsed tone starts
/// soft and steps 3 dB quieter every pulse until the listener says it has
/// gone. The level at that moment is the (relative) threshold.
@MainActor
final class HearingCheckModel: ObservableObject {
    enum Phase: Equatable {
        case intro
        case testing(index: Int)
        case pause(nextIndex: Int)
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .intro
    @Published private(set) var level: Double = HearingCheckModel.startLevel
    @Published private(set) var points: [HearingPoint] = []

    static let startLevel = -30.0
    static let floorLevel = -96.0
    static let stepDB = 3.0
    static let stepSeconds = 0.7

    let frequencies = HearingProfile.testFrequencies
    private let tone = ToneGenerator()
    private var stepTask: Task<Void, Never>?
    private var running = false

    var currentFrequency: Double? {
        if case .testing(let i) = phase { return frequencies[i] }
        return nil
    }

    var progressFraction: Double {
        Double(points.count) / Double(frequencies.count)
    }

    func start() {
        do {
            try tone.start()
            running = true
            points = []
            begin(index: 0)
        } catch {
            phase = .failed("Couldn't start the test tone: \(error.localizedDescription)")
        }
    }

    /// "I can't hear it any more."
    func toneGone() {
        guard case .testing(let i) = phase else { return }
        // Midway between the last step heard and this one.
        record(index: i, threshold: level + Self.stepDB / 2)
    }

    /// "I couldn't hear it at all" at the starting level.
    func neverHeard() {
        guard case .testing(let i) = phase else { return }
        record(index: i, threshold: Self.startLevel + 6)
    }

    func cancel() {
        stepTask?.cancel()
        stepTask = nil
        if running { tone.stop() }
        running = false
    }

    var profile: HearingProfile? {
        guard phase == .finished, points.count == frequencies.count else { return nil }
        return HearingProfile(points: points, measuredAt: Date())
    }

    // MARK: - Steps

    private func begin(index: Int) {
        phase = .testing(index: index)
        level = Self.startLevel
        tone.play(frequency: frequencies[index], levelDBFS: level, restartPulse: true)
        stepTask?.cancel()
        stepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.stepSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard case .testing(let i) = self.phase, i == index else { return }
                let next = self.level - Self.stepDB
                if next < Self.floorLevel {
                    // Heard all the way down: record the floor.
                    self.record(index: index, threshold: Self.floorLevel)
                    return
                }
                self.level = next
                self.tone.play(frequency: self.frequencies[index], levelDBFS: next, restartPulse: false)
            }
        }
    }

    private func record(index: Int, threshold: Double) {
        stepTask?.cancel()
        tone.mute()
        points.append(HearingPoint(frequency: frequencies[index], thresholdDBFS: threshold))
        let next = index + 1
        guard next < frequencies.count else {
            tone.stop()
            running = false
            phase = .finished
            return
        }
        phase = .pause(nextIndex: next)
        stepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.begin(index: next)
        }
    }
}

struct HearingCheckView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var soundManager: SoundProcessingManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = HearingCheckModel()

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()
            VStack(spacing: DS.Spacing.xl) {
                switch model.phase {
                case .intro:
                    intro
                case .testing, .pause:
                    testing
                case .finished:
                    finished
                case .failed(let message):
                    Text(message)
                        .foregroundColor(tokens.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(DS.Spacing.xl)
        }
        .ariaNavigationBar()
        .navigationTitle("Hearing Check")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.cancel() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Image(systemName: "ear")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(tokens.accent)
            Text("About 2 minutes")
                .font(DS.Typography.titleLarge)
                .foregroundColor(tokens.textPrimary)
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                bullet("Wear the IEMs you listen with, in a quiet room.")
                bullet("Set the iPhone volume where you normally listen. Don't change it during the check.")
                bullet("For each tone, tap the button the moment you can no longer hear it.")
                bullet("Your music pauses while the check runs.")
            }
            Text("This compares how sensitive you are at different pitches, relative to 1 kHz and to typical hearing, to build a gentle correction. It is not a medical hearing test.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                if playerManager.isPlaying { playerManager.togglePlayPause() }
                model.start()
            } label: {
                Text("Start")
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.background)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(tokens.textPrimary))
            }
            .buttonStyle(.plain)
        }
    }

    private var testing: some View {
        VStack(spacing: DS.Spacing.xl) {
            ProgressView(value: model.progressFraction)
                .tint(tokens.accent)
            Spacer()
            if let f = model.currentFrequency {
                Text(f >= 1_000 ? String(format: "%g kHz", f / 1000) : String(format: "%g Hz", f))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundColor(tokens.textPrimary)
                    .monospacedDigit()
                Text("Listen for the pulsing tone…")
                    .foregroundColor(tokens.textSecondary)
            } else {
                Text("Next tone…")
                    .foregroundColor(tokens.textSecondary)
            }
            Spacer()
            Button {
                Haptics.light()
                model.toneGone()
            } label: {
                Text("I can't hear it any more")
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.background)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Capsule().fill(tokens.textPrimary))
            }
            .buttonStyle(.plain)
            .disabled(model.currentFrequency == nil)
            Button("I couldn't hear this tone at all") { model.neverHeard() }
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .disabled(model.currentFrequency == nil)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Text("Done")
                .font(DS.Typography.titleLarge)
                .foregroundColor(tokens.textPrimary)
            if let profile = model.profile {
                HearingDeviationChart(profile: profile, tokens: tokens)
                    .frame(height: 140)
                Text("Bars show where you heard less (up) or more (down) than typical, relative to 1 kHz. Aria corrects half of the difference by default; you can change the strength or switch it off in Sound.")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    soundManager.saveHearingProfile(profile)
                    Haptics.success()
                    dismiss()
                } label: {
                    Text("Save and Apply")
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(tokens.background)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(tokens.textPrimary))
                }
                .buttonStyle(.plain)
                Button("Discard") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(tokens.textSecondary)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Text("•").foregroundColor(tokens.accent)
            Text(text)
                .foregroundColor(tokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DS.Typography.body)
    }
}

/// Deviation from typical hearing per test frequency, as centred bars.
struct HearingDeviationChart: View {
    let profile: HearingProfile
    let tokens: DesignTokens

    var body: some View {
        let devs = profile.deviations
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            ForEach(devs.indices, id: \.self) { index in
                let d = devs[index]
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        let half = geo.size.height / 2
                        let clamped = min(15, max(-15, d.deviationDB))
                        let h = CGFloat(abs(clamped) / 15) * half
                        ZStack {
                            Rectangle().fill(tokens.hairline).frame(height: 1)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(clamped >= 0 ? tokens.accent : tokens.textSecondary)
                                .frame(width: 10, height: max(2, h))
                                .offset(y: clamped >= 0 ? -h / 2 : h / 2)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    Text(d.frequency >= 1_000 ? String(format: "%gk", d.frequency / 1000) : String(format: "%g", d.frequency))
                        .font(DS.Typography.micro.monospacedDigit())
                        .foregroundColor(tokens.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(format: "%g hertz: %+.0f decibels versus typical", d.frequency, d.deviationDB))
            }
        }
    }
}
