import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "LibraryAnalysis")

/// Owns per-track audio analysis (`TrackAnalysis`): runs `TrackAnalyzer` off
/// the main thread, one file at a time, and caches results in its own file.
///
/// Storage is separate from the library (`track_analysis.json`), keyed by the
/// local track's UUID. Deleting it loses nothing but analysis; the library
/// database is never read-modify-written here.
///
/// Work is only started on request: the whole library from Library Audit,
/// or a single track when the player needs its waveform.
@MainActor
final class LibraryAnalysisManager: ObservableObject {

    struct Progress: Equatable {
        var done = 0
        var total = 0
        var failed = 0
        var currentTitle: String?
    }

    @Published private(set) var results: [UUID: TrackAnalysis] = [:]
    @Published private(set) var isAnalyzingLibrary = false
    @Published private(set) var progress = Progress()

    private let store: KeyValueStore
    private weak var library: LocalLibraryManager?
    private var libraryTask: Task<Void, Never>?
    private var singleTasks: [UUID: Task<Void, Never>] = [:]
    private var debouncer: Debouncer!

    private struct Persisted: Codable {
        var version: Int
        var entries: [String: TrackAnalysis]
    }

    init(store: KeyValueStore = InMemoryKeyValueStore()) {
        self.store = store
        load()
        debouncer = Debouncer(delay: 1.0) { [weak self] in self?.performSave() }
    }

    func configure(library: LocalLibraryManager) {
        self.library = library
    }

    // MARK: - Lookup

    func analysis(for localID: UUID) -> TrackAnalysis? {
        results[localID]
    }

    /// Player tracks carry ids of the form `local:<UUID>`.
    func analysis(for track: Track) -> TrackAnalysis? {
        Self.localID(of: track).flatMap { results[$0] }
    }

    static func localID(of track: Track) -> UUID? {
        guard track.id.hasPrefix("local:") else { return nil }
        return UUID(uuidString: String(track.id.dropFirst("local:".count)))
    }

    /// Tracks in the library that have no current analysis.
    var pendingCount: Int {
        guard let library else { return 0 }
        return library.tracks.filter { needsAnalysis($0) }.count
    }

    private func needsAnalysis(_ track: LocalTrack) -> Bool {
        guard !track.isMissing else { return false }
        guard let a = results[track.id] else { return true }
        return a.version != TrackAnalysis.currentVersion || a.fileSize != track.fileSizeBytes
    }

    // MARK: - Library radio

    enum RadioResult {
        case tracks([Track])
        /// Not enough of the library has been analysed yet.
        case needsAnalysis(pending: Int)
        /// Seed isn't a local library track.
        case unavailable
    }

    /// Builds an offline mix that flows from `seed`. Requires analysis for
    /// the seed and for a reasonable share of the library.
    func libraryRadio(seed: Track, count: Int = 30) -> RadioResult {
        guard let library, let seedID = Self.localID(of: seed),
              let seedTrack = library.tracks.first(where: { $0.id == seedID }) else {
            return .unavailable
        }
        func candidate(_ t: LocalTrack) -> LibraryRadio.Candidate? {
            guard !t.isMissing, let a = results[t.id] else { return nil }
            return LibraryRadio.Candidate(id: t.id, artist: t.artist ?? "",
                                          album: t.album ?? "", analysis: a)
        }
        guard let seedCandidate = candidate(seedTrack) else {
            return .needsAnalysis(pending: pendingCount)
        }
        let pool = library.tracks.compactMap(candidate)
        guard pool.count >= 6 else { return .needsAnalysis(pending: pendingCount) }

        let ids = LibraryRadio.mix(seed: seedCandidate, candidates: pool, count: count)
        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tracks = ids.compactMap { id -> Track? in
            guard let t = byID[id] else { return nil }
            return t.asPlayerTrack(fileURL: library.fileURL(for: t))
        }
        return .tracks(tracks)
    }

    // MARK: - Galaxy

    /// One track on the Galaxy map.
    struct GalaxyStar: Identifiable, Equatable {
        let id: UUID
        /// −1…1 on both axes.
        let position: SIMD2<Double>
        /// 0 = dark/bassy … 1 = bright (spectral centroid, library-relative).
        let brightness: Double
        /// 0 = quiet … 1 = loud (integrated loudness, library-relative).
        let energy: Double
        let title: String
        let artist: String
    }

    @Published private(set) var galaxy: [GalaxyStar] = []
    @Published private(set) var isBuildingGalaxy = false
    private var galaxyKey: Int?
    private var galaxyTask: Task<Void, Never>?

    /// Analysed, present tracks — the Galaxy's population.
    var galaxyEligibleCount: Int {
        library?.tracks.filter { !$0.isMissing && results[$0.id] != nil }.count ?? 0
    }

    /// Recomputes the map when the set of analysed tracks changed since the
    /// last build. Runs detached; a few seconds for ~500 tracks on an A12.
    func buildGalaxyIfNeeded() {
        guard let library else { return }
        let entries: [(id: UUID, title: String, artist: String, analysis: TrackAnalysis)] =
            library.tracks.compactMap { t in
                guard !t.isMissing, let a = results[t.id] else { return nil }
                return (id: t.id, title: t.title, artist: t.artist ?? "Unknown Artist", analysis: a)
            }
        var hasher = Hasher()
        for e in entries {
            hasher.combine(e.id)
            hasher.combine(e.analysis.version)
            hasher.combine(e.analysis.fileSize)
        }
        let key = hasher.finalize()
        guard key != galaxyKey || galaxy.count != entries.count else { return }
        guard entries.count >= 3 else {
            galaxy = []
            galaxyKey = key
            return
        }

        galaxyTask?.cancel()
        isBuildingGalaxy = true
        let features = entries.map { LibraryRadio.vector($0.analysis) }
        let centroids = entries.map { log2(max($0.analysis.features.spectralCentroidHz, 100)) }
        let loudness = entries.map { $0.analysis.integratedLUFS ?? -14 }
        galaxyTask = Task { [weak self] in
            let job = Task.detached(priority: .utility) { () -> [SIMD2<Double>] in
                GalaxyLayout.embed(features, isCancelled: { Task.isCancelled })
            }
            let positions = await withTaskCancellationHandler {
                await job.value
            } onCancel: {
                job.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.isBuildingGalaxy = false
            guard positions.count == entries.count else { return }
            let bright = Self.rankNormalized(centroids)
            let energy = Self.rankNormalized(loudness)
            self.galaxy = entries.indices.map { i in
                GalaxyStar(id: entries[i].id, position: positions[i], brightness: bright[i],
                           energy: energy[i], title: entries[i].title, artist: entries[i].artist)
            }
            self.galaxyKey = key
        }
    }

    /// Maps values to 0…1 by rank, so a few outliers don't wash out the rest.
    static func rankNormalized(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values.map { _ in 0.5 } }
        let order = values.indices.sorted { values[$0] < values[$1] }
        var out = [Double](repeating: 0, count: values.count)
        for (rank, index) in order.enumerated() {
            out[index] = Double(rank) / Double(values.count - 1)
        }
        return out
    }

    /// Player tracks for a set of local IDs, in the given order.
    func playerTracks(for ids: [UUID]) -> [Track] {
        guard let library else { return [] }
        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in
            guard let t = byID[id], !t.isMissing else { return nil }
            return t.asPlayerTrack(fileURL: library.fileURL(for: t))
        }
    }

    // MARK: - Single track (player waveform)

    /// Analyses the playing track if it has no result yet. Cheap to call
    /// repeatedly; work is deduplicated per track.
    func ensureAnalyzed(_ track: Track) {
        guard let id = Self.localID(of: track),
              let url = track.localFileURL,
              results[id] == nil || results[id]?.version != TrackAnalysis.currentVersion,
              singleTasks[id] == nil else { return }
        singleTasks[id] = Task { [weak self] in
            let result = await Self.runAnalysis(url: url)
            guard let self else { return }
            self.singleTasks[id] = nil
            if let result { self.record(result, for: id) }
        }
    }

    // MARK: - Whole library

    func analyzeLibrary() {
        guard !isAnalyzingLibrary, let library else { return }
        let jobs: [(id: UUID, title: String, url: URL)] = library.tracks
            .filter { needsAnalysis($0) }
            .map { (id: $0.id, title: $0.title, url: library.fileURL(for: $0)) }
        pruneRemovedTracks(keeping: Set(library.tracks.map(\.id)))
        guard !jobs.isEmpty else {
            progress = Progress()
            return
        }
        isAnalyzingLibrary = true
        progress = Progress(done: 0, total: jobs.count)
        libraryTask = Task { [weak self] in
            for job in jobs {
                if Task.isCancelled { break }
                self?.progress.currentTitle = job.title
                // A single-track run may have finished this one meanwhile.
                if let existing = self?.results[job.id], existing.version == TrackAnalysis.currentVersion {
                    self?.progress.done += 1
                    continue
                }
                let result = await Self.runAnalysis(url: job.url)
                guard let self else { return }
                if let result {
                    self.record(result, for: job.id)
                } else if !Task.isCancelled {
                    self.progress.failed += 1
                }
                self.progress.done += 1
            }
            self?.isAnalyzingLibrary = false
            self?.progress.currentTitle = nil
            self?.debouncer.flush()
        }
    }

    func cancelLibraryAnalysis() {
        libraryTask?.cancel()
        libraryTask = nil
        isAnalyzingLibrary = false
        progress.currentTitle = nil
        debouncer.flush()
    }

    /// Detached, utility-priority analysis of one file. Nil on failure or
    /// cancellation (the detached task observes the caller's cancellation).
    private static func runAnalysis(url: URL) async -> TrackAnalysis? {
        let task = Task.detached(priority: .utility) { () -> TrackAnalysis? in
            let info = AudioSourceInfo.probe(fileURL: url)
            do {
                var result = try TrackAnalyzer.analyze(fileURL: url, declaredBitDepth: info?.bitDepth,
                                                       isCancelled: { Task.isCancelled })
                result.codec = info?.codec
                result.isLossless = info?.isLossless
                result.declaredBitDepth = info?.bitDepth
                return result
            } catch {
                return nil
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func record(_ analysis: TrackAnalysis, for id: UUID) {
        results[id] = analysis
        debouncer.call()
    }

    private func pruneRemovedTracks(keeping ids: Set<UUID>) {
        let stale = results.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { results[id] = nil }
        debouncer.call()
    }

    // MARK: - Persistence

    func flushPendingWrites() { debouncer.flush() }

    private func load() {
        guard let data = store.load() else { return }
        do {
            let persisted = try JSONDecoder().decode(Persisted.self, from: data)
            var map: [UUID: TrackAnalysis] = [:]
            for (key, value) in persisted.entries {
                if let id = UUID(uuidString: key) { map[id] = value }
            }
            results = map
        } catch {
            // Only a cache: keep a copy for diagnosis and start empty.
            log.error("analysis cache unreadable: \(error.localizedDescription, privacy: .public)")
            store.backupCorrupt(data)
        }
    }

    private func performSave() {
        var entries: [String: TrackAnalysis] = [:]
        for (id, value) in results { entries[id.uuidString] = value }
        let persisted = Persisted(version: 1, entries: entries)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? store.save(data)
    }
}
