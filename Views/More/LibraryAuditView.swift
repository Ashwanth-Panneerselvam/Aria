import SwiftUI

/// Library quality audit: one-time on-device analysis of every local file,
/// then a report — likely transcodes, fake hi-res, padded bit depth,
/// clipping — plus dynamic range and loudness for every track.
struct LibraryAuditView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var analysisManager: LibraryAnalysisManager
    @EnvironmentObject private var libraryManager: LocalLibraryManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var favoritesManager: FavoritesManager

    @State private var isRepairingTags = false
    @State private var tagRepairResult: String?

    @State private var sort: Sort = .issues
    @State private var selected: Row?

    private var tokens: DesignTokens { themeManager.tokens }

    enum Sort: String, CaseIterable, Identifiable {
        case issues = "Issues First"
        case mostDynamic = "Most Dynamic"
        case leastDynamic = "Least Dynamic"
        case loudest = "Loudest"
        case quietest = "Quietest"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let id: UUID
        let title: String
        let artist: String
        let analysis: TrackAnalysis
        let hints: [QualityHint]

        var formatLabel: String {
            var parts: [String] = []
            parts.append(analysis.codec ?? "—")
            let rate = AudioSourceInfo.formatSampleRate(analysis.sampleRate)?
                .replacingOccurrences(of: " kHz", with: "") ?? "?"
            if let bits = analysis.declaredBitDepth {
                parts.append("\(bits)/\(rate)")
            } else {
                parts.append("\(rate) kHz")
            }
            return parts.joined(separator: " ")
        }
    }

    // MARK: - Data

    private var rows: [Row] {
        libraryManager.tracks.compactMap { t in
            guard let a = analysisManager.results[t.id] else { return nil }
            return Row(id: t.id, title: t.title, artist: t.artist ?? "Unknown Artist",
                       analysis: a, hints: a.hints)
        }
    }

    private func sorted(_ rows: [Row]) -> [Row] {
        switch sort {
        case .issues:
            return rows.sorted {
                let a = $0.hints.first?.severity ?? 0, b = $1.hints.first?.severity ?? 0
                if a != b { return a > b }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .mostDynamic:
            return rows.sorted { ($0.analysis.dynamicRange ?? 0) > ($1.analysis.dynamicRange ?? 0) }
        case .leastDynamic:
            return rows.sorted { ($0.analysis.dynamicRange ?? 99) < ($1.analysis.dynamicRange ?? 99) }
        case .loudest:
            return rows.sorted { ($0.analysis.integratedLUFS ?? -99) > ($1.analysis.integratedLUFS ?? -99) }
        case .quietest:
            return rows.sorted { ($0.analysis.integratedLUFS ?? 0) < ($1.analysis.integratedLUFS ?? 0) }
        }
    }

    // MARK: - Body

    var body: some View {
        let all = rows
        ZStack {
            tokens.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    statusCard(analysedCount: all.count)
                    tagsCard
                    if !all.isEmpty {
                        summaryCard(all)
                        listHeader
                        LazyVStack(spacing: 0) {
                            ForEach(sorted(all)) { row in
                                Button { selected = row } label: { rowView(row) }
                                    .buttonStyle(.plain)
                                Divider().background(tokens.hairline)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                            .fill(tokens.cardSurface))
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                    }
                }
                .padding(DS.Spacing.lg)
            }
        }
        .ariaNavigationBar()
        .navigationTitle("Library Audit")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { row in
            AuditDetailSheet(row: row, tokens: tokens)
        }
    }

    // MARK: - Cards

    private func statusCard(analysedCount: Int) -> some View {
        let total = libraryManager.tracks.filter { !$0.isMissing }.count
        let running = analysisManager.isAnalyzingLibrary
        let p = analysisManager.progress
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text(running ? "Analysing…" : "Analysed \(min(analysedCount, total)) of \(total)")
                    .font(DS.Typography.titleMedium)
                    .foregroundColor(tokens.textPrimary)
                Spacer()
                if running {
                    Button("Stop") { analysisManager.cancelLibraryAnalysis() }
                        .foregroundColor(tokens.accent)
                } else if analysisManager.pendingCount > 0 {
                    Button("Analyse \(analysisManager.pendingCount)") { analysisManager.analyzeLibrary() }
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(tokens.accent)
                }
            }
            if running {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .tint(tokens.accent)
                if let title = p.currentTitle {
                    Text("\(p.done) of \(p.total) · \(title)")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                        .lineLimit(1)
                }
            }
            Text("Each file is decoded once on this iPhone to measure its spectrum, loudness and dynamics. Nothing is uploaded, and your files aren't changed. You can keep listening while it runs.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if p.failed > 0 {
                Text("\(p.failed) files couldn't be read.")
                    .font(DS.Typography.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(tokens.cardSurface))
    }

    private var tagsCard: some View {
        let untagged = libraryManager.tracks.filter {
            !$0.isMissing && LocalLibraryManager.isPlaceholderArtist($0.artist)
        }.count
        let noAlbum = libraryManager.tracks.filter { !$0.isMissing && ($0.album?.isEmpty ?? true) }.count
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("Tags")
                    .font(DS.Typography.titleMedium)
                    .foregroundColor(tokens.textPrimary)
                Spacer()
                if isRepairingTags {
                    ProgressView().tint(tokens.textPrimary)
                } else {
                    Button("Re-read from files") {
                        isRepairingTags = true
                        tagRepairResult = nil
                        Task {
                            let n = await LibraryTagRepair.run(library: libraryManager,
                                                               playlists: playlistsManager,
                                                               favorites: favoritesManager)
                            isRepairingTags = false
                            tagRepairResult = n == 0 ? "Nothing new found in the files." : "Updated \(n) tracks."
                        }
                    }
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.accent)
                }
            }
            Text("\(untagged) tracks without an artist · \(noAlbum) without an album")
                .font(DS.Typography.caption.monospacedDigit())
                .foregroundColor(tokens.textSecondary)
            if let tagRepairResult {
                Text(tagRepairResult)
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.accent)
            }
            NavigationLink {
                MetadataDoctorView()
            } label: {
                Label("Open Metadata Doctor", systemImage: "stethoscope")
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.accent)
            }
            Text("Reads artist, album and title from each file's own tags (including FLAC) and fills in only what's missing.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(tokens.cardSurface))
    }

    private func summaryCard(_ rows: [Row]) -> some View {
        let lossless = rows.filter { $0.analysis.isLossless == true }.count
        let hiRes = rows.filter { $0.analysis.sampleRate > 48_000 || ($0.analysis.declaredBitDepth ?? 0) > 16 }.count
        let flagged = rows.filter { $0.hints.contains { $0.severity >= 2 } }.count
        let drs = rows.compactMap { $0.analysis.dynamicRange }
        let avgDR = drs.isEmpty ? nil : Double(drs.reduce(0, +)) / Double(drs.count)
        let louds = rows.compactMap { $0.analysis.integratedLUFS }.sorted()
        let medianLUFS = louds.isEmpty ? nil : louds[louds.count / 2]

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.md) {
            stat("Lossless", "\(lossless) / \(rows.count)")
            stat("Hi-res files", "\(hiRes)")
            stat("Worth checking", "\(flagged)", highlight: flagged > 0)
            stat("Average DR", avgDR.map { String(format: "DR%.0f", $0) } ?? "—")
            stat("Median loudness", medianLUFS.map { String(format: "%.1f LUFS", $0) } ?? "—")
            stat("Analysed", "\(rows.count)")
        }
    }

    private func stat(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(DS.Typography.micro)
                .tracking(0.8)
                .foregroundColor(tokens.textSecondary)
            Text(value)
                .font(DS.Typography.titleMedium.monospacedDigit())
                .foregroundColor(highlight ? tokens.accent : tokens.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(tokens.cardSurface))
        .accessibilityElement(children: .combine)
    }

    private var listHeader: some View {
        HStack {
            Text("TRACKS")
                .font(DS.Typography.sectionHeader)
                .foregroundColor(tokens.textSecondary)
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(tokens.accent)
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textPrimary)
                    .lineLimit(1)
                Text("\(row.artist) · \(row.formatLabel)")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .lineLimit(1)
                if let hint = row.hints.first {
                    Text(hint.title + (row.hints.count > 1 ? " +\(row.hints.count - 1)" : ""))
                        .font(DS.Typography.captionStrong)
                        .foregroundColor(hint.severity >= 2 ? .orange : tokens.textSecondary)
                }
            }
            Spacer(minLength: DS.Spacing.sm)
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.analysis.dynamicRange.map { "DR\($0)" } ?? "—")
                    .font(DS.Typography.bodyEm.monospacedDigit())
                    .foregroundColor(tokens.textPrimary)
                Text(row.analysis.integratedLUFS.map { String(format: "%.1f LUFS", $0) } ?? "—")
                    .font(DS.Typography.caption.monospacedDigit())
                    .foregroundColor(tokens.textSecondary)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
        .contentShape(Rectangle())
    }
}

/// Every measurement for one file, with the reasoning behind any hints.
private struct AuditDetailSheet: View {
    let row: LibraryAuditView.Row
    let tokens: DesignTokens
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()
                List {
                    Section {
                        if row.hints.isEmpty {
                            Text("No issues detected.")
                                .foregroundColor(tokens.textSecondary)
                        }
                        ForEach(row.hints, id: \.self) { hint in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hint.title).font(DS.Typography.bodyEm)
                                    .foregroundColor(hint.severity >= 2 ? .orange : tokens.textPrimary)
                                Text(hint.detail).font(DS.Typography.caption)
                                    .foregroundColor(tokens.textSecondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: { Text("Findings") }
                        .listRowBackground(tokens.cardSurface)

                    Section {
                        line("Format", row.formatLabel)
                        line("Duration", PlayerScrubber.format(row.analysis.durationSeconds))
                        line("Dynamic range", row.analysis.dynamicRange.map { "DR\($0)" } ?? "—")
                        line("Integrated loudness", row.analysis.integratedLUFS.map { String(format: "%.1f LUFS", $0) } ?? "—")
                        line("Sample peak", String(format: "%.2f dBFS", row.analysis.samplePeakDBFS))
                        line("Content up to", row.analysis.spectralCutoffHz.map { String(format: "%.1f kHz", $0 / 1000) + (row.analysis.cutoffIsSharp ? " (sharp)" : "") } ?? "—")
                        line("Clipped passages", "\(row.analysis.clippedRuns)")
                        line("Tempo", row.analysis.features.tempoBPM.map { String(format: "≈ %.0f BPM", $0) } ?? "—")
                    } header: { Text("Measurements") }
                        .listRowBackground(tokens.cardSurface)

                    Section {
                        Text("Findings are heuristics from the audio itself. A sharp cutoff below ~19.6 kHz in a lossless file usually means it was made from MP3/AAC; some genuine recordings are band-limited too, so trust your ears.")
                            .font(DS.Typography.caption)
                            .foregroundColor(tokens.textSecondary)
                    }
                    .listRowBackground(tokens.cardSurface)
                }
                .scrollContentBackground(.hidden)
            }
            .ariaNavigationBar()
            .navigationTitle(row.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(tokens.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(tokens.textPrimary)
                .monospacedDigit()
        }
        .font(DS.Typography.body)
        .accessibilityElement(children: .combine)
    }
}
