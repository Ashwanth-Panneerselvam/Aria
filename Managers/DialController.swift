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

    /// Album order: file names usually start with the track number.
    private static func albumOrder(_ a: LocalTrack, _ b: LocalTrack) -> Bool {
        a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
    }

    private static func titleOrder(_ a: LocalTrack, _ b: LocalTrack) -> Bool {
        a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    func artistsMenu() -> DialMenu {
        let groups = Dictionary(grouping: localTracks) { $0.artist?.isEmpty == false ? $0.artist! : "Unknown Artist" }
        let names = groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let items = names.map { name -> DialItem in
            let tracks = groups[name] ?? []
            return DialItem(title: name, detail: "\(tracks.count)",
                            action: .submenu { [weak self] in self?.artistMenu(name, tracks) ?? Self.empty(name) })
        }
        return DialMenu(title: "Artists", items: items.isEmpty ? Self.empty("Artists").items : items)
    }

    private func artistMenu(_ name: String, _ tracks: [LocalTrack]) -> DialMenu {
        let byAlbum = Dictionary(grouping: tracks) { $0.album?.isEmpty == false ? $0.album! : "Unknown Album" }
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
            let albumTracks = (byAlbum[album] ?? []).sorted(by: Self.albumOrder)
            return DialItem(title: album, detail: "\(albumTracks.count)",
                            action: .submenu { [weak self] in
                                guard let self else { return Self.empty(album) }
                                let list = self.playerTracks(albumTracks)
                                return DialMenu(title: album, items: self.trackItems(list) { _ in nil })
                            })
        }
        return DialMenu(title: name, items: items)
    }

    func albumsMenu() -> DialMenu {
        struct Key: Hashable { let album: String; let artist: String }
        let groups = Dictionary(grouping: localTracks.filter { $0.album?.isEmpty == false }) {
            Key(album: $0.album!, artist: $0.artist ?? "")
        }
        let keys = groups.keys.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        let items = keys.map { key -> DialItem in
            let tracks = (groups[key] ?? []).sorted(by: Self.albumOrder)
            return DialItem(title: key.album, detail: key.artist.isEmpty ? nil : key.artist,
                            action: .submenu { [weak self] in
                                guard let self else { return Self.empty(key.album) }
                                let list = self.playerTracks(tracks)
                                return DialMenu(title: key.album, items: self.trackItems(list) { _ in nil })
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
