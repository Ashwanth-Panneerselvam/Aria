import Foundation
import AVFoundation
import ImageIO
import MediaPlayer
import UIKit
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "NowPlayingService")

/// Owns the Now Playing / lock-screen / control-center integration, and
/// activates the `AVAudioSession` on demand. Stateless except for the
/// one-time remote command registration flag.
@MainActor
final class NowPlayingService {
    private let urlSession: URLSessionProtocol
    private weak var player: PlayerManager?
    private var remoteCommandsConfigured = false
    private var artworkTask: Task<Void, Never>?
    /// Artwork currently published to Now Playing, tagged with the track it
    /// belongs to. Never attached to a different track's info.
    private var artwork: (trackID: String, art: MPMediaItemArtwork)?
    /// Track whose artwork is being loaded right now (nil when idle).
    private var artworkLoadTrackID: String?
    /// Track whose artwork failed to load, so routine Now Playing updates
    /// (seek, pause) don't re-fetch a broken URL. An explicit `loadArtwork`
    /// call — i.e. the track being played again — still retries.
    private var artworkFailedTrackID: String?

    /// Longest edge the lock-screen bitmap is decoded at. Lock screen and
    /// Control Center draw well under this; decoding a 3000 px embedded cover
    /// at full size would hold ~36 MB for nothing.
    nonisolated static let artworkMaxPixelSize: CGFloat = 1024

    /// Wired by `PlayerManager.configureFavorites(_:)` so the lock-screen Like
    /// command can toggle the current track's favorite state.
    weak var favorites: FavoritesManager?

    init(player: PlayerManager, urlSession: URLSessionProtocol) {
        self.player = player
        self.urlSession = urlSession
    }

    deinit {
        artworkTask?.cancel()
    }

    // MARK: - Public API

    func updateNowPlaying() {
        guard let player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        guard let track = player.currentTrack else {
            artworkTask?.cancel()
            artworkLoadTrackID = nil
            artwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        // A load still running for a *previous* track can never land now.
        if let loading = artworkLoadTrackID, loading != track.id {
            artworkTask?.cancel()
            artworkLoadTrackID = nil
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.playbackRate) : 0.0,
            // Media type lets the system treat this as a music item; without it
            // some lock-screen/CarPlay surfaces won't show transport correctly.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = track.album?.trimmingCharacters(in: .whitespaces), !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        // Only this track's own artwork. Previously the last published image
        // was copied forward unconditionally, so a track without a cover kept
        // showing the previous track's art on the lock screen.
        if let artwork, artwork.trackID == track.id {
            info[MPMediaItemPropertyArtwork] = artwork.art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // Covers the cold-restore path (track rehydrated at launch, no load
        // requested yet) and any track whose load was cancelled above.
        if artwork?.trackID != track.id, artworkLoadTrackID != track.id,
           artworkFailedTrackID != track.id,
           let url = track.thumbnailURL {
            startArtworkLoad(from: url, trackID: track.id)
        }
        // Give the system an explicit play/pause state (it extrapolates elapsed
        // time from rate + this anchor). Without it the lock-screen clock keeps
        // ticking after a pause that didn't originate from the UI.
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
        refreshCommandState()
    }

    /// Keeps the next/prev/like remote commands in sync with queue, history,
    /// and favorite state. Cheap; called on every Now Playing update.
    func refreshCommandState() {
        guard remoteCommandsConfigured, let player else { return }
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = player.hasNext
        c.previousTrackCommand.isEnabled = player.hasPrevious
        if let track = player.currentTrack {
            c.likeCommand.isActive = favorites?.isFavorite(track) ?? false
        }
    }

    func loadArtwork(for track: Track) {
        guard let url = track.thumbnailURL else { return }
        startArtworkLoad(from: url, trackID: track.id)
    }

    /// Loads artwork from any URL — both remote (https) and local
    /// (file://) — for the *current* track. Kept for existing call sites.
    func loadArtwork(from url: URL) {
        guard let trackID = player?.currentTrack?.id else { return }
        startArtworkLoad(from: url, trackID: trackID)
    }

    /// Reads and decodes off the main thread (downsampled with ImageIO), then
    /// publishes only if the same track is still current. Repeated requests
    /// for a track already loaded or loading are ignored.
    private func startArtworkLoad(from url: URL, trackID: String) {
        if artwork?.trackID == trackID || artworkLoadTrackID == trackID { return }
        artworkTask?.cancel()
        artworkLoadTrackID = trackID
        if artworkFailedTrackID == trackID { artworkFailedTrackID = nil }
        let session = urlSession
        artworkTask = Task { [weak self] in
            let data: Data?
            if url.isFileURL {
                data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url, options: .mappedIfSafe)
                }.value
            } else {
                data = (try? await session.data(from: url))?.0
            }
            guard !Task.isCancelled else { return }
            let image: UIImage?
            if let data {
                image = await Task.detached(priority: .utility) {
                    NowPlayingService.decodeArtwork(data, maxPixelSize: NowPlayingService.artworkMaxPixelSize)
                }.value
            } else {
                image = nil
            }
            guard !Task.isCancelled, let self else { return }
            // Load finished for this track either way; clear the marker so a
            // failed load can be retried by a later update.
            if self.artworkLoadTrackID == trackID { self.artworkLoadTrackID = nil }
            guard let image else {
                self.artworkFailedTrackID = trackID
                return
            }
            guard self.player?.currentTrack?.id == trackID else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size,
                                         requestHandler: NowPlayingService.artworkHandler(for: image))
            self.artwork = (trackID, art)
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = art
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let c = MPRemoteCommandCenter.shared()
        // Play and Pause are explicit commands — only act when they'd change
        // state. Routing both to a toggle meant a Pause from a headset or car
        // while already paused (e.g. after unplugging a DAC) started playback.
        c.playCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            if !player.isPlaying { player.togglePlayPause() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            if player.isPlaying { player.togglePlayPause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.player?.togglePlayPause(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player?.seek(to: e.positionTime)
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.player?.nextTrack(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.player?.previousTrack(); return .success }

        // Like / Favorite — toggles the current track in FavoritesManager.
        let like = c.likeCommand
        like.isEnabled = true
        like.localizedTitle = "Favorite"
        like.localizedShortTitle = "Favorite"
        like.addTarget { [weak self] _ in
            guard let self,
                  let track = self.player?.currentTrack,
                  let favorites = self.favorites else { return .commandFailed }
            favorites.toggle(track)
            self.refreshCommandState()
            return .success
        }

        // Initial availability reflects the current state.
        refreshCommandState()
    }

    func activateAudioSession() {
        Task(priority: .userInitiated) {
            let s = AVAudioSession.sharedInstance()
            do {
                try s.setCategory(.playback, mode: .default,
                                  policy: .longFormAudio, options: [])
                try s.setActive(true)
            } catch {
                log.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Internal

    /// Downsampled decode via ImageIO: never materialises more than
    /// `maxPixelSize` on the long edge. Nil for undecodable data.
    nonisolated static func decodeArtwork(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    /// The system calls the artwork handler on a background queue, so it
    /// must not be main-actor isolated (this class is). Builds a nonisolated
    /// closure that aspect-fits the image into the requested size.
    nonisolated static func artworkHandler(for image: UIImage) -> @Sendable (CGSize) -> UIImage {
        return { requested in
            guard requested.width > 0, requested.height > 0,
                  image.size.width > 0, image.size.height > 0 else { return image }
            let scale = min(requested.width / image.size.width,
                            requested.height / image.size.height)
            guard scale < 1 else { return image }
            let target = CGSize(width: (image.size.width * scale).rounded(),
                                height: (image.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        }
    }
}
