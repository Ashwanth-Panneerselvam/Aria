import SwiftUI

/// Now Playing — the DAP screen.
///
/// Layout (top → bottom): header, square artwork sized to the screen, title and
/// artist — album, slim scrubber, transport, secondary actions, and an
/// optional audio-facts strip. Everything is sized from the available space so
/// it fits a 375 × 812 iPhone XS without clipping, and switches to a scrolling
/// column at large Dynamic Type sizes.
///
/// Performance: this view does NOT observe `PlaybackClock`. Only
/// `PlayerScrubber` does, so the 4 Hz position tick never re-renders artwork or
/// controls. No animations run while idle.
struct FullScreenPlayerView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var eqController: EQController
    @EnvironmentObject private var nav: NavigationCoordinator

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    private let dragThreshold: CGFloat = 120
    private let sidePadding: CGFloat = DS.Spacing.xl
    private let artworkRadius: CGFloat = DS.Radius.sm

    private var tokens: DesignTokens { themeManager.tokens }

    /// Above this size the fixed column can't fit, so it scrolls instead.
    private var usesScrollingLayout: Bool { dynamicTypeSize >= .xxLarge }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                tokens.background
                    .ignoresSafeArea()

                if let track = playerManager.currentTrack {
                    if usesScrollingLayout {
                        ScrollView(showsIndicators: false) {
                            playerColumn(track: track, size: geo.size)
                        }
                    } else {
                        playerColumn(track: track, size: geo.size)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    emptyState
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .offset(y: dragOffset)
        .sheet(item: $nav.presentedSheet) { sheet in
            switch sheet {
            case .equalizer:
                EqualizerView()
            case .speedAndPitch:
                SpeedPitchSheet()
            case .addToPlaylist:
                addToPlaylistSheet
            case .queue:
                QueueView()
            case .missingTrackRepair:
                EmptyView()
            }
        }
    }

    // MARK: - Layout

    /// Artwork side for the space available. Takes the column width, capped
    /// at a share of the height so the controls below always fit.
    private func artworkSide(for size: CGSize) -> CGFloat {
        let column = max(size.width - sidePadding * 2, 120)
        let heightShare: CGFloat
        if usesScrollingLayout {
            heightShare = 0.30
        } else {
            heightShare = settingsManager.showAudioInfoStrip ? 0.39 : 0.42
        }
        return max(120, min(column, size.height * heightShare)).rounded(.down)
    }

    private func playerColumn(track: Track, size: CGSize) -> some View {
        let side = artworkSide(for: size)
        let column = max(size.width - sidePadding * 2, 120)
        // Text and controls line up with the artwork edges, but never get
        // narrower than ~300 pt so the transport row stays comfortable.
        let contentWidth = min(column, max(side, 300))

        return VStack(spacing: 0) {
            header
                .gesture(dismissDrag)

            Spacer(minLength: DS.Spacing.sm)

            artwork(side: side)
                .gesture(dismissDrag)

            Spacer(minLength: DS.Spacing.lg)

            trackInfo(track: track)
                .frame(width: contentWidth, alignment: .leading)

            Spacer(minLength: DS.Spacing.md)

            PlayerScrubber(
                tokens: tokens,
                isBuffering: playerManager.isRebuffering || playerManager.playbackState == .loading,
                onSeek: { playerManager.seek(to: $0) }
            )
            .frame(width: contentWidth)

            Spacer(minLength: DS.Spacing.sm)

            transportControls
                .frame(width: contentWidth)

            Spacer(minLength: DS.Spacing.md)

            secondaryControls(track: track)
                .frame(width: contentWidth)

            if settingsManager.showAudioInfoStrip {
                Spacer(minLength: DS.Spacing.md)
                AudioInfoStrip(track: track, tokens: tokens)
                    .frame(width: contentWidth)
            }

            Spacer(minLength: DS.Spacing.sm)
        }
        .padding(.horizontal, sidePadding)
        .frame(width: size.width)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(tokens.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")

            Spacer()

            Text("ARIA")
                .font(DS.Typography.captionStrong)
                .tracking(4)
                .foregroundColor(tokens.textSecondary)
                .accessibilityHidden(true)

            Spacer()

            queueButton
        }
        .padding(.horizontal, sidePadding - 10) // optically align icons with the column
        .padding(.top, DS.Spacing.xs)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var queueButton: some View {
        Button {
            nav.presentedSheet = .queue
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(playerManager.queue.isEmpty ? tokens.textSecondary : tokens.textPrimary)
                .frame(width: 44, height: 44)
                // Count badge anchored inside the 44 pt target so multi-digit
                // counts grow leftward instead of spilling into the edge.
                .overlay(alignment: .topTrailing) {
                    if !playerManager.queue.isEmpty {
                        Text(playerManager.queue.count > 99 ? "99+" : "\(playerManager.queue.count)")
                            .scaledFont(size: 9, weight: .bold, relativeTo: .caption2)
                            .foregroundColor(tokens.background)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(tokens.textPrimary))
                            .padding([.top, .trailing], 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playerManager.queue.isEmpty
                            ? "Show queue"
                            : "Show queue, \(playerManager.queue.count) up next")
    }

    // MARK: - Artwork

    private func artwork(side: CGFloat) -> some View {
        ZStack {
            tokens.background
            if let url = playerManager.currentArtworkURL {
                AsyncCachedImage(url: url, targetSize: side) {
                    ArtworkPlaceholder(tokens: tokens, cornerRadius: artworkRadius)
                }
                // A new identity per URL so the previous track's image is
                // never shown while the next one decodes.
                .id(url)
            } else {
                ArtworkPlaceholder(tokens: tokens, cornerRadius: artworkRadius)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: artworkRadius, style: .continuous))
        .overlay(
            // Defines the edge of dark covers against a black screen.
            RoundedRectangle(cornerRadius: artworkRadius, style: .continuous)
                .stroke(tokens.hairline, lineWidth: 0.5)
        )
        // No glow on OLED; a soft drop shadow only in Light/Dark.
        .shadow(color: tokens.isOLED ? .clear : .black.opacity(0.22),
                radius: tokens.isOLED ? 0 : 12, y: tokens.isOLED ? 0 : 4)
        .accessibilityHidden(true)
    }

    // MARK: - Track Info

    private func trackInfo(track: Track) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title)
                .font(DS.Typography.titleLarge)
                .foregroundColor(tokens.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle(for: track))
                .font(DS.Typography.body)
                .foregroundColor(tokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle(for: track))
    }

    /// "Artist — Album", or just the artist when the album is unknown.
    private func subtitle(for track: Track) -> String {
        if let album = track.album?.trimmingCharacters(in: .whitespaces), !album.isEmpty {
            return "\(track.artist) — \(album)"
        }
        return track.artist
    }

    private func accessibilityTitle(for track: Track) -> String {
        var text = "\(track.title), by \(track.artist)"
        if let album = track.album, !album.isEmpty { text += ", from \(album)" }
        return text
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: 0) {
            transportButton(icon: "shuffle", size: 18,
                            color: playerManager.isShuffled ? tokens.accent : tokens.textSecondary,
                            label: playerManager.isShuffled ? "Shuffle on" : "Shuffle off") {
                playerManager.toggleShuffle()
            }

            transportButton(icon: "backward.fill", size: 26, color: tokens.textPrimary,
                            label: "Previous track") {
                playerManager.previousTrack()
            }

            playPauseButton
                .frame(maxWidth: .infinity)

            transportButton(icon: "forward.fill", size: 26, color: tokens.textPrimary,
                            label: "Next track") {
                playerManager.nextTrack()
            }

            transportButton(icon: playerManager.repeatMode == .one ? "repeat.1" : "repeat", size: 18,
                            color: playerManager.repeatMode != .off ? tokens.accent : tokens.textSecondary,
                            label: repeatAccessibilityLabel) {
                playerManager.cycleRepeatMode()
            }
        }
    }

    private func transportButton(icon: String, size: CGFloat, color: Color, label: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }

    /// Solid disc, background-coloured glyph: the one high-contrast control.
    /// Shows a spinner while the track loads instead of a misleading glyph.
    private var playPauseButton: some View {
        Button {
            Haptics.light()
            playerManager.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(tokens.textPrimary)
                if playerManager.playbackState == .loading {
                    ProgressView()
                        .tint(tokens.background)
                } else {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(tokens.background)
                        // Optical centring: the play triangle sits left-heavy.
                        .offset(x: playerManager.isPlaying ? 0 : 2)
                }
            }
            .frame(width: 66, height: 66)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playerManager.playbackState == .loading
                            ? "Loading"
                            : (playerManager.isPlaying ? "Pause" : "Play"))
    }

    private var repeatAccessibilityLabel: String {
        switch playerManager.repeatMode {
        case .off: return "Repeat mode: off"
        case .one: return "Repeat mode: one"
        case .all: return "Repeat mode: all"
        }
    }

    // MARK: - Secondary actions

    private func secondaryControls(track: Track) -> some View {
        let isFavorite = favoritesManager.isFavorite(track)

        return HStack(spacing: 0) {
            secondaryButton(label: isFavorite ? "Remove from favorites" : "Add to favorites") {
                favoritesManager.toggle(track)
                if favoritesManager.isFavorite(track) {
                    recentlyPlayedManager.trackAdded(track)
                }
            } content: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundColor(isFavorite ? .red : tokens.textSecondary)
            }

            if !track.isLocal {
                DownloadButton(track: track)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }

            secondaryButton(label: "Add to playlist") {
                nav.presentedSheet = .addToPlaylist
            } content: {
                Image(systemName: "text.badge.plus")
                    .foregroundColor(tokens.textSecondary)
            }

            secondaryButton(label: "Equalizer", value: eqAccessibilityValue) {
                nav.presentedSheet = .equalizer
            } content: {
                eqPill
            }

            secondaryButton(label: "Speed and pitch", value: tuningAccessibilityValue) {
                nav.presentedSheet = .speedAndPitch
            } content: {
                Text(speedLabel(playerManager.playbackRate))
                    .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .monospacedDigit()
                    .foregroundColor(isTuningAtDefault ? tokens.textSecondary : tokens.accent)
            }

            // Share the song's name, not the thumbnail image. See
            // `Track.shareText` for why this is never a URL.
            ShareLink(item: track.shareText, subject: Text(track.title)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(tokens.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func secondaryButton<Content: View>(label: String, value: String? = nil,
                                                action: @escaping () -> Void,
                                                @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 18, weight: .regular))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
    }

    /// "EQ" in a hairline capsule; accent-filled when any EQ is active.
    private var eqPill: some View {
        Text("EQ")
            .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
            .tracking(1)
            .foregroundColor(eqController.isEnabled ? tokens.accent : tokens.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(eqController.isEnabled ? tokens.accentSubtle : Color.clear)
            )
            .overlay(
                Capsule().stroke(eqController.isEnabled ? tokens.accent.opacity(0.6) : tokens.hairline,
                                 lineWidth: 1)
            )
    }

    private var eqAccessibilityValue: String {
        if let preset = eqController.parametric { return "On, \(preset.name)" }
        return eqController.isEnabled ? "On" : "Off"
    }

    /// "1×", "0.5×", "1.25×" — `%g` trims trailing zeros.
    private func speedLabel(_ rate: Float) -> String {
        "\(String(format: "%g", Double(rate)))×"
    }

    private var isTuningAtDefault: Bool {
        playerManager.playbackRate == PlaybackTuning.defaultSpeed
            && playerManager.playbackPitch == PlaybackTuning.defaultPitch
    }

    private var tuningAccessibilityValue: String {
        let speed = speedLabel(playerManager.playbackRate)
        guard playerManager.playbackPitch != PlaybackTuning.defaultPitch else { return speed }
        return speed + ", pitch " + String(format: "%+.1f", playerManager.playbackPitch) + " semitones"
    }

    // MARK: - Empty state

    /// Shown when nothing is loaded. No placeholder artwork, no fake specs.
    private var emptyState: some View {
        VStack(spacing: 0) {
            header
                .gesture(dismissDrag)
            Spacer()
            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(tokens.textDisabled)
                    .accessibilityHidden(true)
                Text("Nothing Playing")
                    .font(DS.Typography.titleMedium)
                    .foregroundColor(tokens.textPrimary)
                Text("Choose a track from your library to start listening.")
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DS.Spacing.xxl)
            Spacer()
            Spacer()
        }
    }

    // MARK: - Dismiss gesture

    /// Pull-down-to-close. Attached to the header and artwork only, so it can
    /// never fight the scrubber, the controls or a scrolling layout.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                if value.translation.height > dragThreshold {
                    onDismiss()
                }
                if reduceMotion {
                    dragOffset = 0
                } else {
                    withAnimation(.spring(response: 0.3)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Add to Playlist Sheet

    private var addToPlaylistSheet: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()
                if playlistsManager.playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(tokens.textSecondary)
                        Text("No Playlists")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(tokens.textPrimary)
                        Text("Create a playlist first")
                            .font(.subheadline)
                            .foregroundColor(tokens.textSecondary)
                    }
                } else {
                    List(playlistsManager.playlists) { playlist in
                        Button {
                            if let track = playerManager.currentTrack {
                                playlistsManager.addTrack(track, to: playlist)
                                recentlyPlayedManager.trackAdded(track)
                                nav.presentedSheet = nil
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(playlist.name)
                                        .font(.body)
                                        .foregroundColor(tokens.textPrimary)
                                    Text("\(playlist.tracks.count) tracks")
                                        .font(.caption)
                                        .foregroundColor(tokens.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundColor(tokens.accent)
                            }
                        }
                        .listRowBackground(tokens.background)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .ariaNavigationBar()
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { nav.presentedSheet = nil }
                }
            }
        }
    }
}
