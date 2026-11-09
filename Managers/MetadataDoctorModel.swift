import Combine
import Foundation

/// Scans the library with `MetadataDoctor`, applies the fixes the user keeps
/// and remembers the last batch so it can be undone (persisted, so undo
/// survives a relaunch).
@MainActor
final class MetadataDoctorModel: ObservableObject {
    static let undoKey = "metadata_doctor_undo_v1"
    static let undoLabelKey = "metadata_doctor_undo_label_v1"

    @Published private(set) var artistGroups: [MetadataDoctor.VariantGroup] = []
    @Published private(set) var albumGroups: [MetadataDoctor.VariantGroup] = []
    @Published private(set) var titleFixes: [MetadataDoctor.TitleFix] = []
    @Published private(set) var artworkFixes: [MetadataDoctor.ArtworkFix] = []
    @Published private(set) var missingArtist = 0
    @Published private(set) var missingAlbum = 0
    @Published private(set) var missingArtwork = 0
    @Published private(set) var undoLabel: String?
    @Published var lastResult: String?

    private(set) var items: [MetadataDoctor.Item] = []
    private weak var library: LocalLibraryManager?
    private weak var playlists: PlaylistsManager?
    private weak var favorites: FavoritesManager?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        undoLabel = defaults.data(forKey: Self.undoKey) == nil ? nil : defaults.string(forKey: Self.undoLabelKey)
    }

    func configure(library: LocalLibraryManager, playlists: PlaylistsManager, favorites: FavoritesManager) {
        self.library = library
        self.playlists = playlists
        self.favorites = favorites
        rescan()
    }

    var issueCount: Int {
        artistGroups.count + albumGroups.count + titleFixes.count + artworkFixes.count
    }

    func title(for id: UUID) -> String {
        items.first { $0.id == id }?.title ?? ""
    }

    // MARK: - Scan

    func rescan() {
        guard let library else { return }
        items = library.tracks.filter { !$0.isMissing }.map { t in
            MetadataDoctor.Item(
                id: t.id,
                title: t.title,
                artist: LocalLibraryManager.isPlaceholderArtist(t.artist) ? nil : t.artist,
                album: (t.album?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? nil : t.album,
                hasArtwork: library.artworkURL(for: t).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            )
        }
        artistGroups = MetadataDoctor.artistVariants(items)
        albumGroups = MetadataDoctor.albumVariants(items)
        titleFixes = MetadataDoctor.titleFixes(items)
        artworkFixes = MetadataDoctor.artworkFixes(items)
        missingArtist = items.filter { $0.artist == nil }.count
        missingAlbum = items.filter { $0.album == nil }.count
        missingArtwork = items.filter { !$0.hasArtwork }.count
    }

    // MARK: - Fixes

    /// Renames every spelling in each group to its chosen canonical name.
    func mergeArtists(_ choices: [String: String]) {
        var edits: [UUID: LocalLibraryManager.MetadataEdit] = [:]
        for group in artistGroups {
            guard let target = choices[group.key] else { continue }
            for item in items where item.artist.map(MetadataDoctor.key) == group.key && item.artist != target {
                edits[item.id] = .init(artist: target)
            }
        }
        apply(edits, label: "artist merge")
    }

    func mergeAlbums(_ choices: [String: String]) {
        var edits: [UUID: LocalLibraryManager.MetadataEdit] = [:]
        for group in albumGroups {
            guard let target = choices[group.key] else { continue }
            for item in items where item.album.map(MetadataDoctor.key) == group.key && item.album != target {
                edits[item.id] = .init(album: target)
            }
        }
        apply(edits, label: "album merge")
    }

    func applyTitles(_ fixes: [MetadataDoctor.TitleFix]) {
        var edits: [UUID: LocalLibraryManager.MetadataEdit] = [:]
        for f in fixes { edits[f.id] = .init(title: f.new) }
        apply(edits, label: "title tidy")
    }

    func applyArtwork(_ fixes: [MetadataDoctor.ArtworkFix]) {
        var edits: [UUID: LocalLibraryManager.MetadataEdit] = [:]
        for f in fixes { edits[f.id] = .init(artworkFrom: f.sourceID) }
        apply(edits, label: "artwork copy")
    }

    func applySplits(_ fixes: [MetadataDoctor.SplitFix]) {
        var edits: [UUID: LocalLibraryManager.MetadataEdit] = [:]
        for f in fixes { edits[f.id] = .init(title: f.title, artist: f.artist, album: f.album) }
        apply(edits, label: "title split")
    }

    func splitFixes(_ pattern: MetadataDoctor.SplitPattern) -> [MetadataDoctor.SplitFix] {
        MetadataDoctor.splitFixes(items, pattern: pattern)
    }

    var likelySplitPattern: MetadataDoctor.SplitPattern { MetadataDoctor.likelyPattern(items) }

    private func apply(_ edits: [UUID: LocalLibraryManager.MetadataEdit], label: String) {
        guard let library, !edits.isEmpty else { return }
        let previous = library.applyMetadataEdits(edits)
        guard !previous.isEmpty else {
            lastResult = "Nothing to change."
            return
        }
        saveUndo(previous, label: label)
        propagate(Set(previous.map(\.id)))
        lastResult = "Fixed \(previous.count) track\(previous.count == 1 ? "" : "s")."
        rescan()
    }

    // MARK: - Undo

    func undo() {
        guard let library, let data = defaults.data(forKey: Self.undoKey),
              let previous = try? JSONDecoder().decode([LocalTrack].self, from: data) else { return }
        let restored = library.restoreMetadata(previous)
        defaults.removeObject(forKey: Self.undoKey)
        defaults.removeObject(forKey: Self.undoLabelKey)
        undoLabel = nil
        propagate(restored)
        lastResult = "Undid the last \(restored.count == 1 ? "change" : "\(restored.count) changes")."
        rescan()
    }

    private func saveUndo(_ previous: [LocalTrack], label: String) {
        guard let data = try? JSONEncoder().encode(previous) else { return }
        defaults.set(data, forKey: Self.undoKey)
        let text = "\(label) · \(previous.count) track\(previous.count == 1 ? "" : "s")"
        defaults.set(text, forKey: Self.undoLabelKey)
        undoLabel = text
    }

    private func propagate(_ changed: Set<UUID>) {
        guard let library, let playlists, let favorites else { return }
        LibraryTagRepair.propagate(changed, library: library, playlists: playlists, favorites: favorites)
    }
}
