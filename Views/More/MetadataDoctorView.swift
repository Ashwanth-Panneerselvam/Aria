import SwiftUI

/// Metadata Doctor: finds messy metadata (spelling variants, junk in titles,
/// missing artwork/artist/album) and fixes it in bulk after a preview. Edits
/// Aria's library only — never the audio files — and the last fix can be
/// undone.
struct MetadataDoctorView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var libraryManager: LocalLibraryManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var favoritesManager: FavoritesManager

    @StateObject private var model = MetadataDoctorModel()
    @State private var isRereading = false

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    summary
                    if let label = model.undoLabel { undoCard(label) }
                    if let result = model.lastResult {
                        Text(result)
                            .font(DS.Typography.caption)
                            .foregroundColor(tokens.accent)
                    }
                    issues
                    missingCard
                    Text("Changes apply to Aria's library — titles, artists and albums shown in the app, playlists and favourites. Your music files are never modified.")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Spacing.lg)
            }
        }
        .ariaNavigationBar()
        .navigationTitle("Metadata Doctor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.configure(library: libraryManager, playlists: playlistsManager, favorites: favoritesManager)
        }
    }

    // MARK: - Overview

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.issueCount == 0 ? "Looking healthy" : "\(model.issueCount) things to tidy")
                .font(DS.Typography.titleLarge)
                .foregroundColor(tokens.textPrimary)
            Text("\(model.items.count) tracks checked")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
        }
    }

    private func undoCard(_ label: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last fix").font(DS.Typography.captionStrong).foregroundColor(tokens.textSecondary)
                Text(label).font(DS.Typography.body).foregroundColor(tokens.textPrimary)
            }
            Spacer()
            Button("Undo") {
                Haptics.medium()
                model.undo()
            }
            .font(DS.Typography.bodyEm)
            .foregroundColor(tokens.accent)
        }
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(tokens.cardSurface))
    }

    private var issues: some View {
        VStack(spacing: 0) {
            issueRow("Artist spellings", icon: "person.2", count: model.artistGroups.count,
                     detail: "Same artist written different ways") {
                VariantMergeView(model: model, kind: .artist)
            }
            divider
            issueRow("Album spellings", icon: "square.stack", count: model.albumGroups.count,
                     detail: "Same album written different ways") {
                VariantMergeView(model: model, kind: .album)
            }
            divider
            issueRow("Messy titles", icon: "textformat", count: model.titleFixes.count,
                     detail: "Track numbers, “(Official Audio)”, underscores") {
                TitleFixView(model: model)
            }
            divider
            issueRow("Artwork from album-mates", icon: "photo.on.rectangle", count: model.artworkFixes.count,
                     detail: "Tracks missing a cover that their album has") {
                ArtworkFixView(model: model)
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(tokens.cardSurface))
    }

    private var divider: some View {
        Divider().background(tokens.hairline).padding(.leading, 52)
    }

    private func issueRow<Destination: View>(_ title: String, icon: String, count: Int, detail: String,
                                             @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(count > 0 ? tokens.accent : tokens.textDisabled)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Typography.body).foregroundColor(tokens.textPrimary)
                    Text(detail).font(DS.Typography.caption).foregroundColor(tokens.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(count == 0 ? "✓" : "\(count)")
                    .font(DS.Typography.bodyEm.monospacedDigit())
                    .foregroundColor(count == 0 ? tokens.textDisabled : tokens.accent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tokens.textDisabled)
            }
            .padding(DS.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel("\(title), \(count == 0 ? "nothing to fix" : "\(count) to fix")")
    }

    private var missingCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("STILL MISSING")
                .font(DS.Typography.sectionHeader)
                .foregroundColor(tokens.textSecondary)
            HStack(spacing: DS.Spacing.xl) {
                stat("\(model.missingArtist)", "no artist")
                stat("\(model.missingAlbum)", "no album")
                stat("\(model.missingArtwork)", "no artwork")
            }
            HStack(spacing: DS.Spacing.lg) {
                if isRereading {
                    ProgressView().tint(tokens.textPrimary)
                } else {
                    Button("Re-read tags from files") {
                        isRereading = true
                        Task {
                            let n = await LibraryTagRepair.run(library: libraryManager,
                                                               playlists: playlistsManager,
                                                               favorites: favoritesManager)
                            isRereading = false
                            model.lastResult = n == 0 ? "No new tags found in the files." : "Filled in \(n) tracks from their tags."
                            model.rescan()
                        }
                    }
                }
                if model.missingArtist > 0 {
                    NavigationLink("Split from titles") { SplitFixView(model: model) }
                }
            }
            .font(DS.Typography.bodyEm)
            .foregroundColor(tokens.accent)
            .padding(.top, DS.Spacing.xs)
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(tokens.cardSurface))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(DS.Typography.titleMedium.monospacedDigit()).foregroundColor(tokens.textPrimary)
            Text(label).font(DS.Typography.caption).foregroundColor(tokens.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces

private struct ApplyBar: View {
    let title: String
    let enabled: Bool
    let tokens: DesignTokens
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.success()
            action()
        }) {
            Text(title)
                .font(DS.Typography.bodyEm)
                .foregroundColor(tokens.background)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(enabled ? tokens.textPrimary : tokens.textDisabled))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(DS.Spacing.lg)
        .background(tokens.background)
    }
}

private struct CheckRow<Content: View>: View {
    let isOn: Bool
    let tokens: DesignTokens
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isOn ? tokens.accent : tokens.textDisabled)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 3) { content() }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Spelling variants

private struct VariantMergeView: View {
    enum Kind { case artist, album }

    @ObservedObject var model: MetadataDoctorModel
    let kind: Kind
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var choice: [String: String] = [:]
    @State private var included: Set<String> = []
    @State private var initialised = false

    private var tokens: DesignTokens { themeManager.tokens }
    private var groups: [MetadataDoctor.VariantGroup] {
        kind == .artist ? model.artistGroups : model.albumGroups
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(groups) { group in
                        groupRow(group)
                            .listRowBackground(tokens.cardSurface)
                    }
                } footer: {
                    Text("Tap a spelling to make it the one used. Untick a group to leave it as it is.")
                        .foregroundColor(tokens.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            ApplyBar(title: "Merge \(included.count) group\(included.count == 1 ? "" : "s")",
                     enabled: !included.isEmpty, tokens: tokens) {
                let picks = choice.filter { included.contains($0.key) }
                if kind == .artist { model.mergeArtists(picks) } else { model.mergeAlbums(picks) }
                dismiss()
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .ariaNavigationBar()
        .navigationTitle(kind == .artist ? "Artist Spellings" : "Album Spellings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialised else { return }
            initialised = true
            for g in groups { choice[g.key] = g.suggested }
            included = Set(groups.map(\.key))
        }
    }

    private func groupRow(_ group: MetadataDoctor.VariantGroup) -> some View {
        let isIncluded = included.contains(group.key)
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Toggle(isOn: Binding(
                    get: { isIncluded },
                    set: { if $0 { included.insert(group.key) } else { included.remove(group.key) } }
                )) {
                    Text("\(group.trackCount) tracks")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                }
                .tint(tokens.accent)
            }
            ForEach(group.spellings.indices, id: \.self) { index in
                let spelling = group.spellings[index]
                let selected = choice[group.key] == spelling.name
                Button {
                    choice[group.key] = spelling.name
                    included.insert(group.key)
                } label: {
                    HStack {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(selected ? tokens.accent : tokens.textDisabled)
                        Text(spelling.name)
                            .foregroundColor(tokens.textPrimary)
                            .fontWeight(selected ? .semibold : .regular)
                        Spacer()
                        Text("\(spelling.count)")
                            .font(DS.Typography.caption.monospacedDigit())
                            .foregroundColor(tokens.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isIncluded)
                .opacity(isIncluded ? 1 : 0.5)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }
}

// MARK: - Titles

private struct TitleFixView: View {
    @ObservedObject var model: MetadataDoctorModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var initialised = false

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.titleFixes) { fix in
                        CheckRow(isOn: selected.contains(fix.id), tokens: tokens, toggle: { toggle(fix.id) }) {
                            Text(fix.old)
                                .font(DS.Typography.caption)
                                .foregroundColor(tokens.textSecondary)
                                .strikethrough()
                                .lineLimit(2)
                            Text(fix.new)
                                .font(DS.Typography.body)
                                .foregroundColor(tokens.textPrimary)
                                .lineLimit(2)
                            Text(fix.reasons.joined(separator: " · "))
                                .font(DS.Typography.micro)
                                .foregroundColor(tokens.textDisabled)
                        }
                        .listRowBackground(tokens.cardSurface)
                    }
                } header: {
                    selectAllHeader(count: model.titleFixes.count, selected: selected.count) {
                        selected = selected.count == model.titleFixes.count ? [] : Set(model.titleFixes.map(\.id))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            ApplyBar(title: "Tidy \(selected.count) title\(selected.count == 1 ? "" : "s")",
                     enabled: !selected.isEmpty, tokens: tokens) {
                model.applyTitles(model.titleFixes.filter { selected.contains($0.id) })
                dismiss()
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .ariaNavigationBar()
        .navigationTitle("Messy Titles")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialised else { return }
            initialised = true
            selected = Set(model.titleFixes.map(\.id))
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func selectAllHeader(count: Int, selected: Int, action: @escaping () -> Void) -> some View {
        HStack {
            Text("\(selected) of \(count) selected")
            Spacer()
            Button(selected == count ? "Select None" : "Select All", action: action)
                .foregroundColor(tokens.accent)
        }
        .textCase(nil)
    }
}

// MARK: - Artwork

private struct ArtworkFixView: View {
    @ObservedObject var model: MetadataDoctorModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var initialised = false

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.artworkFixes) { fix in
                        CheckRow(isOn: selected.contains(fix.id), tokens: tokens, toggle: {
                            if selected.contains(fix.id) { selected.remove(fix.id) } else { selected.insert(fix.id) }
                        }) {
                            Text(model.title(for: fix.id))
                                .font(DS.Typography.body)
                                .foregroundColor(tokens.textPrimary)
                                .lineLimit(1)
                            Text("Cover from “\(model.title(for: fix.sourceID))” · \(fix.album)")
                                .font(DS.Typography.caption)
                                .foregroundColor(tokens.textSecondary)
                                .lineLimit(2)
                        }
                        .listRowBackground(tokens.cardSurface)
                    }
                } footer: {
                    Text("Each track gets its own copy of the cover, so removing one track never affects another.")
                        .foregroundColor(tokens.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            ApplyBar(title: "Copy artwork to \(selected.count) track\(selected.count == 1 ? "" : "s")",
                     enabled: !selected.isEmpty, tokens: tokens) {
                model.applyArtwork(model.artworkFixes.filter { selected.contains($0.id) })
                dismiss()
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .ariaNavigationBar()
        .navigationTitle("Missing Artwork")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialised else { return }
            initialised = true
            selected = Set(model.artworkFixes.map(\.id))
        }
    }
}

// MARK: - Split from titles

private struct SplitFixView: View {
    @ObservedObject var model: MetadataDoctorModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var pattern: MetadataDoctor.SplitPattern = .titleArtistAlbum
    @State private var excluded: Set<UUID> = []
    @State private var initialised = false

    private var tokens: DesignTokens { themeManager.tokens }
    private var fixes: [MetadataDoctor.SplitFix] { model.splitFixes(pattern) }
    private var chosen: [MetadataDoctor.SplitFix] { fixes.filter { !excluded.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Picker("Titles look like", selection: $pattern) {
                        ForEach(MetadataDoctor.SplitPattern.allCases) { Text($0.label).tag($0) }
                    }
                    .tint(tokens.accent)
                    .listRowBackground(tokens.cardSurface)
                } footer: {
                    Text("For tracks with no artist tag whose title holds the details. Check the preview — anything that looks wrong, untick it.")
                        .foregroundColor(tokens.textSecondary)
                }
                Section {
                    if fixes.isEmpty {
                        Text("No titles match this pattern.")
                            .foregroundColor(tokens.textSecondary)
                            .listRowBackground(tokens.cardSurface)
                    }
                    ForEach(fixes) { fix in
                        CheckRow(isOn: !excluded.contains(fix.id), tokens: tokens, toggle: {
                            if excluded.contains(fix.id) { excluded.remove(fix.id) } else { excluded.insert(fix.id) }
                        }) {
                            Text(fix.oldTitle)
                                .font(DS.Typography.caption)
                                .foregroundColor(tokens.textSecondary)
                                .lineLimit(2)
                            field("Title", fix.title)
                            field("Artist", fix.artist)
                            if let album = fix.album { field("Album", album) }
                        }
                        .listRowBackground(tokens.cardSurface)
                    }
                } header: {
                    Text("\(chosen.count) of \(fixes.count) selected").textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
            ApplyBar(title: "Split \(chosen.count) title\(chosen.count == 1 ? "" : "s")",
                     enabled: !chosen.isEmpty, tokens: tokens) {
                model.applySplits(chosen)
                dismiss()
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .ariaNavigationBar()
        .navigationTitle("Split from Titles")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialised else { return }
            initialised = true
            pattern = model.likelySplitPattern
        }
        .onChange(of: pattern) { _ in excluded = [] }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(DS.Typography.micro)
                .foregroundColor(tokens.textDisabled)
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(DS.Typography.body)
                .foregroundColor(tokens.textPrimary)
                .lineLimit(1)
        }
    }
}
