import SwiftUI

/// Crossfeed, personal tuning and hearing profile — the processing that runs
/// after EQ/AutoEQ. Every change applies to playback immediately.
struct SoundProcessingView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var soundManager: SoundProcessingManager

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    crossfeedCard
                    tuningCard
                    hearingCard
                    responseCard
                    Text("Applied after EQ and AutoEQ, to everything you play. Gain is lowered automatically when boosts could clip.")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                        .padding(.horizontal, DS.Spacing.sm)
                }
                .padding(DS.Spacing.lg)
            }
        }
        .ariaNavigationBar()
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Crossfeed

    private var crossfeedCard: some View {
        card(title: "Crossfeed") {
            Picker("Crossfeed", selection: $soundManager.settings.crossfeed) {
                ForEach(SoundProcessingSettings.CrossfeedLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Text(crossfeedDescription)
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var crossfeedDescription: String {
        switch soundManager.settings.crossfeed {
        case .off:
            return "IEMs send each channel to one ear only, so hard-panned mixes (early stereo, a lot of jazz) can sound split and tiring. Crossfeed blends a softened copy of each side into the other, like listening to speakers."
        case .gentle:
            return "Light blend (650 Hz, 9.5 dB, Meier-style). Keeps width, takes the edge off extreme panning."
        case .natural:
            return "Moderate blend (700 Hz, 6 dB, Chu Moy-style). A good default for older stereo recordings."
        case .strong:
            return "Strong blend (700 Hz, 4.5 dB). Most speaker-like; narrows the stage noticeably."
        }
    }

    // MARK: - Tuning

    private var tuningCard: some View {
        card(title: "Personal Tuning") {
            Toggle("Enabled", isOn: $soundManager.settings.tuningEnabled)
                .tint(tokens.accent)
                .foregroundColor(tokens.textPrimary)
            slider("Bass", "105 Hz shelf", value: $soundManager.settings.bassDB,
                   range: SoundProcessingSettings.bassRange)
            slider("Warmth", "250 Hz", value: $soundManager.settings.warmthDB,
                   range: SoundProcessingSettings.midRange)
            slider("Presence", "3 kHz", value: $soundManager.settings.presenceDB,
                   range: SoundProcessingSettings.midRange)
            slider("Treble", "8 kHz shelf", value: $soundManager.settings.trebleDB,
                   range: SoundProcessingSettings.trebleRange)
            if !soundManager.settings.isTuningFlat {
                Button("Reset to flat") { soundManager.resetTuning() }
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.accent)
            }
            Text("Taste adjustments on top of your AutoEQ profile — the correction stays, this adds your preference.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(soundManager.settings.tuningEnabled ? 1 : 0.85)
    }

    private func slider(_ name: String, _ detail: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textPrimary)
                Text(detail)
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                Spacer()
                Text(String(format: "%+.1f dB", value.wrappedValue))
                    .font(DS.Typography.caption.monospacedDigit())
                    .foregroundColor(value.wrappedValue == 0 ? tokens.textSecondary : tokens.accent)
            }
            Slider(value: value, in: range, step: 0.5)
                .tint(tokens.accent)
                .disabled(!soundManager.settings.tuningEnabled)
                .accessibilityLabel(name)
                .accessibilityValue(String(format: "%+.1f decibels", value.wrappedValue))
        }
    }

    // MARK: - Hearing

    private var hearingCard: some View {
        card(title: "Hearing Profile") {
            if let profile = soundManager.settings.hearing {
                HearingDeviationChart(profile: profile, tokens: tokens)
                    .frame(height: 110)
                Toggle("Apply correction", isOn: $soundManager.settings.applyHearing)
                    .tint(tokens.accent)
                    .foregroundColor(tokens.textPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Strength").foregroundColor(tokens.textPrimary)
                        Spacer()
                        Text("\(Int((soundManager.settings.hearingStrength * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundColor(tokens.textSecondary)
                    }
                    .font(DS.Typography.body)
                    Slider(value: $soundManager.settings.hearingStrength, in: 0...1, step: 0.05)
                        .tint(tokens.accent)
                        .disabled(!soundManager.settings.applyHearing)
                        .accessibilityLabel("Correction strength")
                }
                HStack {
                    NavigationLink("Retake check") { HearingCheckView() }
                        .foregroundColor(tokens.accent)
                    Spacer()
                    Button("Delete", role: .destructive) { soundManager.deleteHearingProfile() }
                }
                .font(DS.Typography.bodyEm)
                Text("Measured \(profile.measuredAt.formatted(date: .abbreviated, time: .omitted)) with the IEMs and volume you used then.")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
            } else {
                Text("A 2-minute listening check finds where your ears are less sensitive than typical, then adds a gentle correction. Not a medical test.")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    HearingCheckView()
                } label: {
                    Label("Take the hearing check", systemImage: "ear")
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(tokens.accent)
                }
            }
        }
    }

    // MARK: - Response

    private var responseCard: some View {
        let settings = soundManager.settings
        let filters = settings.allFilters
        return card(title: "Combined Response") {
            ResponseCurve(settings: settings, tokens: tokens)
                .frame(height: 120)
                .accessibilityLabel("Frequency response of tuning and hearing correction")
            HStack {
                Text(filters.isEmpty ? "Flat" : "\(filters.count) filter\(filters.count == 1 ? "" : "s")")
                Spacer()
                if settings.headroomDB < 0 {
                    Text(String(format: "Headroom %.1f dB", settings.headroomDB))
                }
            }
            .font(DS.Typography.caption.monospacedDigit())
            .foregroundColor(tokens.textSecondary)
        }
    }

    // MARK: - Card

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(title.uppercased())
                .font(DS.Typography.sectionHeader)
                .foregroundColor(tokens.textSecondary)
            content()
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(tokens.cardSurface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .stroke(tokens.hairline, lineWidth: 0.5))
    }
}

/// Log-frequency plot (20 Hz–20 kHz, ±12 dB) of the tuning + hearing filters.
struct ResponseCurve: View {
    let settings: SoundProcessingSettings
    let tokens: DesignTokens

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let minF = log10(20.0), maxF = log10(20_000.0)
            func x(_ f: Double) -> CGFloat { CGFloat((log10(f) - minF) / (maxF - minF)) * w }
            func y(_ db: Double) -> CGFloat { h / 2 - CGFloat(max(-12, min(12, db)) / 12) * (h / 2) }

            // Grid: 0 dB line and decade marks.
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: h / 2))
            grid.addLine(to: CGPoint(x: w, y: h / 2))
            for f in [100.0, 1_000.0, 10_000.0] {
                grid.move(to: CGPoint(x: x(f), y: 0))
                grid.addLine(to: CGPoint(x: x(f), y: h))
            }
            context.stroke(grid, with: .color(tokens.hairline), lineWidth: 1)

            let filters = settings.allFilters
            var curve = Path()
            let steps = 90
            for i in 0...steps {
                let f = pow(10, minF + (maxF - minF) * Double(i) / Double(steps))
                let db = filters.isEmpty ? 0 : settings.responseDB(at: f, filters: filters)
                let point = CGPoint(x: x(f), y: y(db))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(tokens.accent), lineWidth: 2)
        }
    }
}
