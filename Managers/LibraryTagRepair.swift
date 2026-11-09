import Foundation

/// Runs `LocalLibraryManager.repairTagsFromFiles()` and carries the fixed
/// titles / artists / albums into playlists and favourites, which keep their
/// own copies of tracks. Runs automatically once per install of this
/// version, and on demand from Library Audit.
@MainActor
enum LibraryTagRepair {
    static let doneKey = "library_tag_repair_v1"

    static func runIfNeeded(library: LocalLibraryManager, playlists: PlaylistsManager,
                            favorites: FavoritesManager) async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        _ = await run(library: library, playlists: playlists, favorites: favorites)
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Returns how many library tracks were updated.
    @discardableResult
    static func run(library: LocalLibraryManager, playlists: PlaylistsManager,
                    favorites: FavoritesManager) async -> Int {
        let changed = await library.repairTagsFromFiles()
        guard !changed.isEmpty else { return 0 }
        propagate(changed, library: library, playlists: playlists, favorites: favorites)
        return changed.count
    }

    /// Carries library changes into the track copies kept by playlists and
    /// favourites.
    static func propagate(_ changed: Set<UUID>, library: LocalLibraryManager,
                          playlists: PlaylistsManager, favorites: FavoritesManager) {
        guard !changed.isEmpty else { return }
        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let replacement: (Track) -> Track? = { track in
            guard let id = LibraryAnalysisManager.localID(of: track), changed.contains(id),
                  let local = byID[id] else { return nil }
            return local.asPlayerTrack(fileURL: library.fileURL(for: local))
        }
        playlists.refreshTracks(replacement)
        favorites.refreshTracks(replacement)
    }
}
