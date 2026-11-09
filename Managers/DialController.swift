import Foundation
import Combine

/// Display options for dial mode, stored in UserDefaults.
enum DialLCDColor: String, CaseIterable {
    case amber, green, ice

    static let storageKey = "dial_lcd_color"
    static let clickSoundKey = "dial_click_sound"

    var displayName: String {
        switch self {
        case .amber: return "Amber"
        case .green: return "Green"
        case .ice: return "Ice"
        }
    }

    var next: DialLCDColor {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Builds dial mode's menu tree from the library, playlists and favourites,
/// and owns the `DialNavigator`. Configured once the environment is known.
@MainActor
final class DialController: ObservableObject {
    let navigator = DialNavigator(root: { DialMenu(title: "Aria", items: []) })

    private weak var library: LocalLibraryManager?
    private weak var playlists: PlaylistsManager?
    private weak var favorites: FavoritesManager?
    private weak var player: PlayerManager?
    private weak var analysis: LibraryAnalysisManager?
    private let defaults = UserDefaults.standard
    private var configured = false

    func configure(library: LocalLibraryManager, playlists: PlaylistsManager,
                   favorites: FavoritesManager, player: PlayerManager,
                   analysis: LibraryAnalysisManager) {
        guard !configured else { return }
        configured = true
        self.library = library
        self.playlists = playlists
        self.favorites = favorites
        self.player = player
        self.analysis = analysis
        navigator.player = player
        navigator.rootBuilder = { [weak self] in
            self?.rootMenu() ?? DialMenu(title: "Aria", items: [])
        }
        navigator.resetToRoot()
    }

    // MARK: - Root

    func rootMenu() -> DialMenu {
        DialMenu(title: "Aria") { [weak self] in
            guard let self else { return [] }
            var items: [DialItem] = []
            if let track = self.player?.currentTrack {
                items.append(DialItem(title: "Now Playing", detail: track.title, action: .nowPlaying))
            }
            items += [
                DialItem(title: "Artists", action: .submenu { [weak self] in self?.artistsMenu() ?? Self.empty("Artists") }),
                DialItem(title: "Albums", action: .submenu { [weak self] in self?.albumsMenu() ?? Self.empty("Albums") }),
                DialItem(title: "Songs", action: .submenu { [weak self] in self?.songsMenu() ?? Self.empty("Songs") }),
                DialItem(title: "Playlists", action: .submenu { [weak self] in self?.playlistsMenu() ?? Self.empty("Playlists") }),
                DialItem(title: "Favourites", action: .submenu { [weak self] in self?.favouritesMenu() ?? Self.empty("Favourites") }),
                DialItem(title: "Shuffle All", action: .perform { [weak self] in self?.shuffleAll() ?? .stay }),
                DialItem(title: "Library Radio", action: .perform { [weak self] in self?.startRadio() ?? .stay }),
                DialItem(title: "Display", action: .submenu { [weak self] in self?.displayMenu() ?? Self.empty("Display") }),
                DialItem(title: "Standard Interface", action: .perform { .exit }),
            ]
            return items
        }
    }

    static func empty(_ title: String) -> DialMenu {
        DialMenu(title: title, items: [DialItem(title: "(empty)", action: .perform { .stay })])
    }

    // MARK: - Library

    private var localTracks: [LocalTrack] {
        (library?.tracks ?? []).filter { !$0.isMissing }
    }

    private func playerTracks(_ tracks: [LocalTrack]) -> [Track] {
        guard let library else { return [] }
        return tracks.map { $0.asPlayerTrack(fileURL: library.fileURL(for: $0)) }
    }

    /// Track rows that play `list` from the chosen row.
    private func trackItems(_ list: [Track], detail: (Track) -> String?) -> [DialItem] {
        guard !list.isEmpty else { return [DialItem(title: "(no songs)", action: .perform { .stay })] }
        return list.enumerated().map { i, t in
            DialItem(title: t.title, detail: detail(t), action: .play(tracks: list, index: i))
        }
    }

    /// Album order from the files' disc/track tags (read on demand — FLAC
    /// headers only, a few KB per file), falling back to title.
    private func albumOrdered(_ tracks: [LocalTrack]) -> [LocalTrack] {
        guard let library else { return tracks.sorted(by: Self.titleOrder) }
        let keyed = tracks.map { t -> (LocalTrack, Int, Int) in
            let tags = AudioTags.read(fileURL: library.fileURL(for: t))
            return (t, tags?.discNumber ?? 1, tags?.trackNumber ?? Int.max)
        }
        return keyed.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return Self.titleOrder(a.0, b.0)
        }.map(\.0)
    }

    private static func displayArtist(_ t: LocalTrack) -> String {
        LocalLibraryManager.isPlaceholderArtist(t.artist) ? "Unknown Artist" : t.artist!
    }

    private static func albumName(_ t: LocalTrack) -> String? {
        guard let a = t.album?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return nil }
        return a
    }

    private static func titleOrder(_ a: LocalTrack, _ b: LocalTrack) -> Bool {
        a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    func artistsMenu() -> DialMenu {
        let groups = Dictionary(grouping: localTracks) { Self.displayArtist($0) }
        let names = groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let items = names.map { name -> DialItem in
            let tracks = groups[name] ?? []
            return DialItem(title: name, detail: "\(tracks.count)",
                            action: .submenu { [weak self] in self?.artistMenu(name, tracks) ?? Self.empty(name) })
        }
        return DialMenu(title: "Artists", items: items.isEmpty ? Self.empty("Artists").items : items)
    }

    private func artistMenu(_ name: String, _ tracks: [LocalTrack]) -> DialMenu {
        let byAlbum = Dictionary(grouping: tracks) { Self.albumName($0) ?? "Unknown Album" }
        let albums = byAlbum.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var items: [DialItem] = [
            DialItem(title: "All Songs", detail: "\(tracks.count)",
                     action: .submenu { [weak self] in
                         guard let self else { return Self.empty(name) }
                         let list = self.playerTracks(tracks.sorted(by: Self.titleOrder))
                         return DialMenu(title: name, items: self.trackItems(list) { _ in nil })
                     }),
        ]
        items += albums.map { album in
            let albumTracks = byAlbum[album] ?? []
            return DialItem(title: album, detail: "\(albumTracks.count)",
                            action: .submenu { [weak self] in
                                guard let self else { return Self.empty(album) }
                                let list = self.playerTracks(self.albumOrdered(albumTracks))
                                return DialMenu(title: album, items: self.trackItems(list) { _ in nil })
                            })
        }
        return DialMenu(title: name, items: items)
    }

    func albumsMenu() -> DialMenu {
        // Grouped by album name (case-insensitive) so compilations with many
        // artists stay one album; the detail shows the artist or "Various".
        let groups = Dictionary(grouping: localTracks.filter { Self.albumName($0) != nil }) {
            Self.albumName($0)!.lowercased()
        }
        let keys = groups.keys.sorted { a, b in
            let na = Self.albumName(groups[a]![0])!, nb = Self.albumName(groups[b]![0])!
            return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending
        }
        let items = keys.map { key -> DialItem in
            let tracks = groups[key] ?? []
            let name = Self.albumName(tracks[0]) ?? key
            let artists = Set(tracks.map(Self.displayArtist))
            let detail = artists.count == 1 ? artists.first : "Various"
            return DialItem(title: name, detail: detail,
                            action: .submenu { [weak self] in
                                guard let self else { return Self.empty(name) }
                                let list = self.playerTracks(self.albumOrdered(tracks))
                                return DialMenu(title: name, items: self.trackItems(list) { _ in nil })
                            })
        }
        return DialMenu(title: "Albums", items: items.isEmpty ? Self.empty("Albums").items : items)
    }

    func songsMenu() -> DialMenu {
        let list = playerTracks(localTracks.sorted(by: Self.titleOrder))
        return DialMenu(title: "Songs", items: trackItems(list) { $0.artist })
    }

    func playlistsMenu() -> DialMenu {
        let all = playlists?.sortedPlaylists ?? []
        let items = all.map { playlist in
            DialItem(title: playlist.name, detail: "\(playlist.tracks.count)",
                     action: .submenu { [weak self] in
                         guard let self else { return Self.empty(playlist.name) }
                         return DialMenu(title: playlist.name,
                                         items: self.trackItems(playlist.tracks) { $0.artist })
                     })
        }
        return DialMenu(title: "Playlists", items: items.isEmpty ? Self.empty("Playlists").items : items)
    }

    func favouritesMenu() -> DialMenu {
        let list = favorites?.tracks ?? []
        return DialMenu(title: "Favourites", items: trackItems(list) { $0.artist })
    }

    // MARK: - Actions

    private func shuffleAll() -> DialOutcome {
        let list = playerTracks(localTracks).shuffled()
        guard !list.isEmpty, let player else { return .message("No songs on this iPhone") }
        player.playSlice(list, startIndex: 0)
        return .nowPlaying
    }

    private func startRadio() -> DialOutcome {
        guard let player, let analysis, let seed = player.currentTrack else {
            return .message("Play a song first")
        }
        switch analysis.libraryRadio(seed: seed) {
        case .tracks(let tracks) where !tracks.isEmpty:
            player.clearQueue()
            for t in tracks { player.addToQueue(t) }
            return .nowPlaying
        case .needsAnalysis:
            return .message("Run Library Audit first")
        default:
            return .message("Needs a song on this iPhone")
        }
    }

    func displayMenu() -> DialMenu {
        DialMenu(title: "Display") { [weak self] in
            guard let self else { return [] }
            let colour = DialLCDColor(rawValue: self.defaults.string(forKey: DialLCDColor.storageKey) ?? "") ?? .amber
            let click = self.defaults.bool(forKey: DialLCDColor.clickSoundKey)
            return [
                DialItem(title: "Colour", detail: colour.displayName, action: .perform { [weak self] in
                    self?.defaults.set(colour.next.rawValue, forKey: DialLCDColor.storageKey)
                    return .refresh
                }),
                DialItem(title: "Click Sound", detail: click ? "On" : "Off", action: .perform { [weak self] in
                    self?.defaults.set(!click, forKey: DialLCDColor.clickSoundKey)
                    return .refresh
                }),
            ]
        }
    }
}
