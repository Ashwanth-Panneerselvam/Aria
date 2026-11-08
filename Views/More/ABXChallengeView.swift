import SwiftUI

/// "Can you actually hear lossless?" — a proper ABX test on your own music,
/// IEMs and DAC. A = the original, B = the same excerpt through AAC at the
/// chosen bitrate, X = one of them at random. 16 trials, then statistics.
struct ABXChallengeView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var libraryManager: LocalLibraryManager
    @EnvironmentObject private var analysisManager: LibraryAnalysisManager

    @StateObject private var session = ABXSession()
    @State private var selectedTrackID: UUID?
    @State private var bitrate = 256_000
    @State private var startFraction = 0.3
    @State private var showPicker = false

    private var tokens: DesignTokens { themeManager.tokens }
    private let bitrates = [128_000, 192_000, 256_000, 320_000]

    // MARK: - Track choice

    /// Lossless local tracks at ≤ 48 kHz (by analysis when available,
    /// otherwise by file extension).
    private var eligible: [LocalTrack] {
        libraryManager.tracks.filter { t in
            guard !t.isMissing else { return false }
            if let a = analysisManager.results[t.id] {
                return (a.isLossless ?? false) && a.sampleRate <= 48_000
            }
            let ext = (t.fileName as NSString).pathExtension.lowercased()
            return ["flac", "wav", "aif", "aiff"].contains(ext)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var selectedTrack: LocalTrack? {
        let pool = eligible
        if let id = selectedTrackID, let t = pool.first(where: { $0.id == id }) { return t }
        if let current = playerManager.currentTrack,
           let id = LibraryAnalysisManager.localID(of: current),
           let t = pool.first(where: { $0.id == id }) { return t }
        return pool.first
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    switch session.phase {
                    case .idle, .failed:
                        setup
                    case .preparing:
                        HStack(spacing: DS.Spacing.sm) {
                            ProgressView().tint(tokens.textPrimary)
                            Text("Encoding the excerpt…").foregroundColor(tokens.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    case .testing:
                        testing
                    case .finished:
                        results
                    }
                }
                .padding(DS.Spacing.lg)
            }
        }
        .ariaNavigationBar()
        .navigationTitle("ABX Challenge")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { session.end() }
        .sheet(isPresented: $showPicker) { trackPicker }
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Text("Can you hear lossless?")
                .font(DS.Typography.titleLarge)
                .foregroundColor(tokens.textPrimary)
            Text("You'll hear A (the original file) and B (the same 15 seconds compressed to AAC). X is secretly one of them. Switch as often as you like, then say which one X is. Sixteen rounds; the score tells you whether you heard a real difference or were guessing.")
                .font(DS.Typography.body)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = session.phase {
                Text(message).font(DS.Typography.caption).foregroundColor(.orange)
            }

            card {
                Text("TRACK").font(DS.Typography.sectionHeader).foregroundColor(tokens.textSecondary)
                Button { showPicker = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedTrack?.title ?? "No lossless tracks found")
                                .foregroundColor(tokens.textPrimary)
                                .lineLimit(1)
                            Text(selectedTrack?.artist ?? "FLAC, WAV or AIFF at 44.1/48 kHz")
                                .font(DS.Typography.caption)
                                .foregroundColor(tokens.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(tokens.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(eligible.isEmpty)

                if let t = selectedTrack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Excerpt starts at").foregroundColor(tokens.textPrimary)
                            Spacer()
                            Text(PlayerScrubber.format(startFraction * (t.durationSeconds ?? 0)))
                                .monospacedDigit()
                                .foregroundColor(tokens.textSecondary)
                        }
                        .font(DS.Typography.body)
                        Slider(value: $startFraction, in: 0...0.9)
                            .tint(tokens.accent)
                            .accessibilityLabel("Excerpt start")
                    }
                }
            }

            card {
                Text("AAC BITRATE").font(DS.Typography.sectionHeader).foregroundColor(tokens.textSecondary)
                Picker("Bitrate", selection: $bitrate) {
                    ForEach(bitrates, id: \.self) { Text("\($0 / 1000)").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("kbps. 256 is what most stores sell; 128 is easier to catch.")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
            }

            Button {
                guard let t = selectedTrack else { return }
                if playerManager.isPlaying { playerManager.togglePlayPause() }
                session.prepare(url: libraryManager.fileURL(for: t), title: t.title,
                                start: startFraction * (selectedTrack?.durationSeconds ?? 0), bitrate: bitrate)
            } label: {
                Text("Start Challenge")
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.background)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(tokens.textPrimary))
            }
            .buttonStyle(.plain)
            .disabled(selectedTrack == nil)

            Text("Both versions play through a separate audio path with no EQ or processing, aligned to the sample and matched in level, so compression is the only difference. Use the IEMs and DAC you normally listen with.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Testing

    private var testing: some View {
        VStack(spacing: DS.Spacing.xl) {
            VStack(spacing: 4) {
                Text("Round \(session.trial) of \(ABXSession.totalTrials)")
                    .font(DS.Typography.titleMedium.monospacedDigit())
                    .foregroundColor(tokens.textPrimary)
                Text("\(session.trackTitle) · AAC \(session.bitrate / 1000) kbps")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .lineLimit(1)
                ProgressView(value: Double(session.trial - 1), total: Double(ABXSession.totalTrials))
                    .tint(tokens.accent)
                    .padding(.top, DS.Spacing.sm)
            }

            HStack(spacing: DS.Spacing.md) {
                sourceButton(.a, caption: "original")
                sourceButton(.x, caption: "mystery")
                sourceButton(.b, caption: "AAC")
            }

            HStack(spacing: DS.Spacing.lg) {
                Button { session.restart() } label: {
                    Label("From the top", systemImage: "backward.end.fill")
                }
                .disabled(session.playing == nil)
                Button { session.stopPlayback() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(session.playing == nil)
            }
            .font(DS.Typography.caption)
            .foregroundColor(tokens.textSecondary)

            Text("X is…")
                .font(DS.Typography.body)
                .foregroundColor(tokens.textSecondary)
            HStack(spacing: DS.Spacing.md) {
                answerButton("A") { session.answer(xIsA: true) }
                answerButton("B") { session.answer(xIsA: false) }
            }
            Button("End test") { session.end() }
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sourceButton(_ source: ABXSession.Source, caption: String) -> some View {
        let active = session.playing == source
        return Button {
            Haptics.selection()
            session.play(source)
        } label: {
            VStack(spacing: 4) {
                Text(source.rawValue)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(caption)
                    .font(DS.Typography.caption)
            }
            .foregroundColor(active ? tokens.background : tokens.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(active ? tokens.textPrimary : tokens.cardSurface))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .stroke(source == .x ? tokens.accent : tokens.hairline, lineWidth: source == .x ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(source.rawValue), \(caption)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func answerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.bodyEm)
                .foregroundColor(tokens.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Capsule().stroke(tokens.textPrimary.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("X is \(title)")
    }

    // MARK: - Results

    private var results: some View {
        let verdict = session.verdict
        return VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Text("\(session.correct) / \(ABXSession.totalTrials)")
                .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(tokens.textPrimary)
            Text(verdict.title)
                .font(DS.Typography.titleLarge)
                .foregroundColor(session.pValue < 0.05 ? tokens.accent : tokens.textPrimary)
            Text(verdict.detail)
                .font(DS.Typography.body)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pure guessing scores 12/16 or better only 3.8 % of the time. Level correction applied: \(String(format: "%+.2f", session.levelCorrectionDB)) dB.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                session.end()
            } label: {
                Text("New Challenge")
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.background)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(tokens.textPrimary))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Picker

    private var trackPicker: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()
                List(eligible) { t in
                    Button {
                        selectedTrackID = t.id
                        showPicker = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).foregroundColor(tokens.textPrimary).lineLimit(1)
                            Text(t.artist ?? "Unknown Artist")
                                .font(DS.Typography.caption)
                                .foregroundColor(tokens.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .listRowBackground(tokens.background)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .ariaNavigationBar()
            .navigationTitle("Choose a Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPicker = false }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) { content() }
            .padding(DS.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(tokens.cardSurface))
    }
}
