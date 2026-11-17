import SwiftUI

/// Settings for volume leveling: on/off, track or album, target level,
/// clean-boost option, what the playing track gets, and library coverage.
struct VolumeLevelingView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var leveling: VolumeLevelingManager
    @EnvironmentObject private var analysisManager: LibraryAnalysisManager

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    mainCard
                    if leveling.settings.enabled {
                        nowPlayingCard
                        optionsCard
                        coverageCard
                    }
                    Text("One fixed volume change per track — the music's own dynamics are untouched. Applied after EQ and Sound, to tracks in your library. Streams play unchanged.")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DS.Spacing.sm)
                }
                .padding(DS.Spacing.lg)
            }
        }
        .ariaNavigationBar()
        .navigationTitle("Volume Leveling")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cards

    private var mainCard: some View {
        card(title: "Volume Leveling") {
            Toggle("Same volume for every song", isOn: $leveling.settings.enabled)
                .tint(tokens.accent)
                .foregroundColor(tokens.textPrimary)
            Text("Loud tracks are turned down and quiet ones turned up, so you don't have to reach for the volume between songs.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nowPlayingCard: some View {
        card(title: "Now Playing") {
            if let title = leveling.currentTrackTitle, let decision = leveling.currentDecision {
                Text(title)
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.textPrimary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.formatGain(decision.gainDB))
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(decision.reading == nil ? tokens.textSecondary : tokens.accent)
                    Spacer()
                }
                Text(Self.explanation(decision))
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(leveling.currentTrackTitle == nil
                     ? "Nothing playing."
                     : "This track isn't from your library, so it plays unchanged.")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
            }
        }
    }

    private var optionsCard: some View {
        card(title: "Options") {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Level by")
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textPrimary)
                Picker("Level by", selection: $leveling.settings.mode) {
                    ForEach(VolumeLevelingSettings.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(leveling.settings.mode == .track
                     ? "Every track at the same loudness. Best for shuffle and mixes."
                     : "Every album at the same loudness; tracks within an album keep the levels they were mastered at. Best for listening to whole albums. Needs the whole album measured, otherwise falls back to the track.")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            levelControl

            Toggle("Never limit peaks", isOn: $leveling.settings.cleanBoostsOnly)
                .tint(tokens.accent)
                .foregroundColor(tokens.textPrimary)
            Text(leveling.settings.cleanBoostsOnly
                 ? "Quiet tracks are only raised as far as their loudest peak allows, so nothing is ever limited. A few very dynamic recordings may stay slightly quieter than the rest."
                 : "Quiet tracks are raised fully. If that would push a peak past full scale, a fast limiter catches just that peak instead of letting it clip.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Level slider

    private var target: Double { leveling.settings.targetLUFS }

    private var levelControl: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Level")
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textPrimary)
                Spacer()
                Text(Self.formatTarget(target))
                    .font(DS.Typography.bodyEm.monospacedDigit())
                    .foregroundColor(tokens.accent)
            }

            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundColor(tokens.textSecondary)
                Slider(value: $leveling.settings.targetLUFS,
                       in: VolumeLevelingSettings.targetRange,
                       step: VolumeLevelingSettings.targetStep)
                    .tint(tokens.accent)
                    .accessibilityLabel("Level")
                    .accessibilityValue(Self.spokenTarget(target))
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundColor(tokens.textSecondary)
            }
            .onChange(of: leveling.settings.targetLUFS) { _ in Haptics.selection() }

            HStack(spacing: DS.Spacing.sm) {
                ForEach(VolumeLevelingSettings.Level.allCases) { level in
                    presetChip(level)
                }
            }

            Text(levelDescription)
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetChip(_ level: VolumeLevelingSettings.Level) -> some View {
        let selected = leveling.settings.preset == level
        return Button {
            Haptics.light()
            leveling.settings.targetLUFS = level.targetLUFS
        } label: {
            VStack(spacing: 1) {
                Text(level.displayName)
                    .font(DS.Typography.caption.weight(.semibold))
                Text(String(format: "%.0f", level.targetLUFS))
                    .font(DS.Typography.micro.monospacedDigit())
                    .opacity(0.8)
            }
            .foregroundColor(selected ? tokens.background : tokens.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? tokens.accent : tokens.elevatedSurface))
            .overlay(Capsule().stroke(selected ? Color.clear : tokens.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(level.displayName), \(Int(level.targetLUFS)) LUFS")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var levelDescription: String {
        let vsNormal = target - VolumeLevelingSettings.Level.normal.targetLUFS
        var text: String
        if abs(vsNormal) < 0.01 {
            text = "A balanced level; most tracks are turned down a little."
        } else {
            let amount = String(format: "%.1f", abs(vsNormal))
            text = "\(amount) dB \(vsNormal > 0 ? "louder" : "quieter") than Normal."
        }
        if target > -14 {
            text += leveling.settings.cleanBoostsOnly
                ? " Above Loud, many quiet tracks can't be raised that far without limiting, so with Never limit peaks on they'll stay a bit quieter."
                : " Above Loud, many quiet tracks need big boosts, so the limiter will work more."
        } else if target > -14.01 {
            text += " Similar to most streaming services."
        } else if target <= -18 {
            text += " Lots of headroom: almost nothing needs boosting. Handy if your IEMs are too loud even at the lowest volume step."
        }
        return text
    }

    static func formatTarget(_ lufs: Double) -> String {
        String(format: "%.1f LUFS", lufs)
    }

    static func spokenTarget(_ lufs: Double) -> String {
        String(format: "minus %.1f LUFS", -lufs)
    }

    private var coverageCard: some View {
        card(title: "Library") {
            let measured = leveling.measuredCount
            let total = leveling.libraryCount
            Text("\(measured) of \(total) tracks measured")
                .font(DS.Typography.body.monospacedDigit())
                .foregroundColor(tokens.textPrimary)
            if total > 0 {
                ProgressView(value: Double(measured), total: Double(max(total, 1)))
                    .tint(tokens.accent)
            }
            Text("Tracks are measured the first time they play, and the next songs in your queue are measured ahead. ReplayGain tags in FLAC files are used until then. A track with neither starts at its normal volume and settles to its level a few seconds in.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if analysisManager.isAnalyzingLibrary {
                let p = analysisManager.progress
                HStack {
                    ProgressView().tint(tokens.accent)
                    Text("Measuring \(p.done) of \(p.total)…")
                        .font(DS.Typography.caption.monospacedDigit())
                        .foregroundColor(tokens.textSecondary)
                    Spacer()
                    Button("Stop") { analysisManager.cancelLibraryAnalysis() }
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(tokens.accent)
                }
            } else if measured < total {
                Button {
                    Haptics.light()
                    analysisManager.analyzeLibrary()
                } label: {
                    Text("Measure the whole library now")
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(tokens.accent)
                }
                Text("Runs on this iPhone, one track at a time. Best done while charging; you can leave this screen.")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Text

    static func formatGain(_ db: Double) -> String {
        if abs(db) < 0.05 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }

    static func explanation(_ d: LevelingDecision) -> String {
        guard let r = d.reading else {
            return "Not measured yet — playing at its normal volume. It'll settle to its level once measured."
        }
        var text = "Loudness " + String(format: "%.1f", r.lufs) + " LUFS (" + r.source.displayName + ")."
        if d.limitedByPeaks {
            text += " Boost reduced to keep peaks clean."
        } else if d.limiterMayAct {
            text += " The limiter may catch the loudest peaks."
        }
        return text
    }

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
