import SwiftUI

/// Compact player docked above the tab bar.
///
/// True Black: a solid black bar with hairlines — integrated with the screen,
/// not a floating glass panel. Light/Dark keep the original translucent
/// material. The progress line is its own small view (`MiniProgressLine`), the
/// only piece that observes `PlaybackClock`, so position ticks don't re-render
/// the artwork or buttons.
struct MiniPlayerView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager
    var onTap: () -> Void

    private var tokens: DesignTokens { themeManager.tokens }

    private let artworkSide: CGFloat = 40

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            // The open-player tap target: artwork + titles. Buttons on the
            // right are separate controls, not nested inside this one.
            Button(action: onTap) {
                HStack(spacing: DS.Spacing.md) {
                    if let track = playerManager.currentTrack {
                        artworkThumbnail
                            .frame(width: artworkSide, height: artworkSide)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(tokens.hairline, lineWidth: 0.5)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .scaledFont(size: 14, weight: .semibold, relativeTo: .footnote)
                                .lineLimit(1)
                                .foregroundColor(tokens.textPrimary)
                            Text(track.artist)
                                .scaledFont(size: 12, relativeTo: .caption)
                                .lineLimit(1)
                                .foregroundColor(tokens.textSecondary)
                        }
                    } else {
                        Text("Not playing")
                            .scaledFont(size: 13, relativeTo: .footnote)
                            .foregroundColor(tokens.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint("Opens the full screen player")

            trailingButtons
        }
        .padding(.leading, DS.Spacing.md)
        .padding(.trailing, DS.Spacing.xs)
        .frame(minHeight: 56)
        // Fixed-height chrome: let text scale through the standard sizes but
        // clamp before the accessibility sizes clip the bar.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(background)
        .overlay(alignment: .top) {
            if playerManager.currentTrack != nil {
                MiniProgressLine(tokens: tokens)
            }
        }
    }

    // MARK: - Pieces

    private var background: some View {
        Rectangle()
            .fill(tokens.isOLED
                  ? AnyShapeStyle(tokens.chromeBackground)
                  : AnyShapeStyle(Material.ultraThinMaterial))
    }

    private var accessibilityTitle: String {
        guard let track = playerManager.currentTrack else { return "Not playing" }
        return "\(track.title), \(track.artist)"
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let url = playerManager.currentArtworkURL {
            AsyncCachedImage(url: url, targetSize: artworkSide) {
                ArtworkPlaceholder(tokens: tokens, cornerRadius: 4)
            }
            .id(url)
        } else {
            ArtworkPlaceholder(tokens: tokens, cornerRadius: 4)
        }
    }

    private var trailingButtons: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.light()
                playerManager.togglePlayPause()
            } label: {
                Group {
                    if playerManager.playbackState == .loading {
                        ProgressView()
                            .tint(tokens.textPrimary)
                    } else {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .foregroundColor(tokens.textPrimary)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerManager.playbackState == .loading
                                ? "Loading"
                                : (playerManager.isPlaying ? "Pause" : "Play"))

            Button {
                Haptics.light()
                playerManager.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17))
                    .foregroundColor(playerManager.hasNext ? tokens.textPrimary : tokens.textDisabled)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playerManager.hasNext)
            .accessibilityLabel("Next track")
        }
    }
}

/// 2 pt progress line pinned to the top edge of the mini player. Observes
/// `PlaybackClock` itself so only this line repaints on each tick.
private struct MiniProgressLine: View {
    @EnvironmentObject private var clock: PlaybackClock
    let tokens: DesignTokens

    var body: some View {
        GeometryReader { geo in
            let fraction = clock.duration > 0
                ? min(max(clock.currentTime / clock.duration, 0), 1)
                : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(tokens.isOLED ? tokens.hairline : tokens.textPrimary.opacity(0.12))
                Rectangle().fill(tokens.isOLED ? tokens.textSecondary : tokens.textPrimary.opacity(0.55))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
