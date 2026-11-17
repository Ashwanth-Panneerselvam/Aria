import Foundation
import Combine

/// Chooses a volume-leveling gain for every track the player starts, and
/// re-applies it live when the settings change or the playing track has
/// just been measured.
///
/// Loudness comes from, in order of preference:
/// - Track mode: Aria's own measurement → the file's ReplayGain track tag →
///   its ReplayGain album tag.
/// - Album mode: Aria's measurement of the whole album (every track of it
///   measured) → ReplayGain album tag → the track-mode sources.
///
/// A track with none of these starts at 0 dB, gets measured in the
/// background (the same analysis the waveform seek bar uses, cached in
/// `track_analysis.json`) and glides to its gain once that finishes. The
/// next tracks in the queue are measured ahead of time so that's rare.
///
/// Only local library tracks are leveled; streams play as before.
@MainActor
final class VolumeLevelingManager: ObservableObject {
    static let storageKey = "volume_leveling_v1"

    @Published var settings: VolumeLevelingSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            player?.refreshLeveling()
            refreshDecision()
        }
    }

    /// The decision for the track playing now (for the settings screen).
    @Published private(set) var currentDecision: LevelingDecision?
    @Published private(set) var currentTrackTitle: String?

    private let defaults: UserDefaults
    private weak var library: LocalLibraryManager?
    private weak var analysis: LibraryAnalysisManager?
    private weak var player: PlayerManager?
    private var cancellables: Set<AnyCancellable> = []
    /// ReplayGain tags per file; `.some(nil)` caches "has none".
    private var replayGainCache: [UUID: ReplayGainInfo?] = [:]
    private var lastAppliedForTrack: (id: String, config: LevelingConfig)?
    /// How many upcoming queue tracks to measure ahead.
    private let lookahead = 2
    private var lookaheadTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(VolumeLevelingSettings.self, from: data) {
            settings = decoded
        } else {
            settings = VolumeLevelingSettings()
        }
    }

    func configure(library: LocalLibraryManager, analysis: LibraryAnalysisManager, player: PlayerManager) {
        guard self.player !== player else { return }
        self.library = library
        self.analysis = analysis
        self.player = player
        player.levelingResolver = { [weak self] track in
            guard let self else { return .off }
            let config = self.config(for: track)
            self.lastAppliedForTrack = (track.id, config)
            return config
        }

        // `@Published` emits before the property changes, so use the value.
        player.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in
                Task { @MainActor [weak self] in self?.trackChanged(track) }
            }
            .store(in: &cancellables)

        // A measurement finishing (for this track or, in album mode, one of
        // its album-mates) can change the gain of what's playing.
        analysis.$results
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.measurementsChanged() }
            .store(in: &cancellables)

        // A library change (rename via the Metadata Doctor, re-import) can
        // change albums and files.
        library.$tracks
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.replayGainCache.removeAll()
                self?.measurementsChanged()
            }
            .store(in: &cancellables)

        player.refreshLeveling()
        trackChanged(player.currentTrack)
    }

    // MARK: - Decisions

    func config(for track: Track) -> LevelingConfig {
        guard settings.enabled, localTrack(for: track) != nil else { return .off }
        let decision = decision(for: track)
        // The limiter stays in place even before the track is measured, so
        // the tap exists from the first sample and a later gain can glide in.
        return LevelingConfig(gainDB: decision.gainDB, limiter: true)
    }

    func decision(for track: Track) -> LevelingDecision {
        VolumeLeveling.decide(reading(for: track), settings: settings)
    }

    /// The loudness figure used for a track, by the preference order above.
    func reading(for track: Track) -> LoudnessReading? {
        guard let local = localTrack(for: track) else { return nil }
        let measured = measuredReading(local)
        let tags = replayGain(for: local)
        let tagTrack = tags?.trackGainDB.map {
            LoudnessReading(lufs: VolumeLeveling.lufs(fromReplayGain: $0),
                            peakDBFS: VolumeLeveling.dbfs(fromLinearPeak: tags?.trackPeak),
                            source: .replayGainTrack)
        }
        let tagAlbum = tags?.albumGainDB.map {
            LoudnessReading(lufs: VolumeLeveling.lufs(fromReplayGain: $0),
                            peakDBFS: VolumeLeveling.dbfs(fromLinearPeak: tags?.albumPeak ?? tags?.trackPeak),
                            source: .replayGainAlbum)
        }
        switch settings.mode {
        case .track:
            return measured ?? tagTrack ?? tagAlbum
        case .album:
            return measuredAlbumReading(local) ?? tagAlbum ?? measured ?? tagTrack
        }
    }

    /// How many present library tracks have a loudness measurement.
    var measuredCount: Int {
        guard let library, let analysis else { return 0 }
        return library.tracks.filter { !$0.isMissing && analysis.results[$0.id]?.integratedLUFS != nil }.count
    }

    var libraryCount: Int {
        library?.tracks.filter { !$0.isMissing }.count ?? 0
    }

    // MARK: - Sources

    private func localTrack(for track: Track) -> LocalTrack? {
        guard let id = LibraryAnalysisManager.localID(of: track) else { return nil }
        return library?.tracks.first { $0.id == id }
    }

    private func measuredReading(_ local: LocalTrack) -> LoudnessReading? {
        guard let a = analysis?.results[local.id],
              a.version == TrackAnalysis.currentVersion,
              a.fileSize == local.fileSizeBytes,
              let lufs = a.integratedLUFS else { return nil }
        return LoudnessReading(lufs: lufs, peakDBFS: a.samplePeakDBFS, source: .measuredTrack)
    }

    /// Album loudness, only when every present track of the album is measured.
    private func measuredAlbumReading(_ local: LocalTrack) -> LoudnessReading? {
        guard let library, let analysis, let members = albumMembers(of: local, in: library.tracks),
              members.count >= 2 else { return nil }
        var rows: [(lufs: Double, durationSeconds: Double, peakDBFS: Double)] = []
        for m in members {
            guard let a = analysis.results[m.id], a.version == TrackAnalysis.currentVersion,
                  let lufs = a.integratedLUFS else { return nil }
            rows.append((lufs: lufs, durationSeconds: a.durationSeconds, peakDBFS: a.samplePeakDBFS))
        }
        return VolumeLeveling.albumReading(rows)
    }

    /// Present tracks sharing this track's album (spelling-insensitive).
    /// Nil when the track has no real album name.
    private func albumMembers(of local: LocalTrack, in tracks: [LocalTrack]) -> [LocalTrack]? {
        guard let album = local.album, !album.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let key = MetadataDoctor.key(album)
        guard !key.isEmpty else { return nil }
        return tracks.filter { !$0.isMissing && $0.album.map(MetadataDoctor.key) == key }
    }

    private func replayGain(for local: LocalTrack) -> ReplayGainInfo? {
        if let cached = replayGainCache[local.id] { return cached }
        // Only FLAC is parsed; it reads the small metadata blocks at the start
        // of the file and seeks past embedded pictures.
        let info: ReplayGainInfo?
        if let url = library?.fileURL(for: local) {
            info = AudioTags.readReplayGain(fileURL: url)
        } else {
            info = nil
        }
        replayGainCache[local.id] = .some(info)
        return info
    }

    // MARK: - Updates

    private func trackChanged(_ track: Track?) {
        currentTrackTitle = track?.title
        refreshDecision(for: track)
        measureAhead(current: track)
    }

    private func measurementsChanged() {
        guard let track = player?.currentTrack else { return }
        let config = config(for: track)
        if lastAppliedForTrack?.id != track.id || lastAppliedForTrack?.config != config {
            player?.refreshLeveling()
        }
        refreshDecision(for: track)
    }

    private func refreshDecision(for track: Track? = nil) {
        guard let track = track ?? player?.currentTrack, settings.enabled, localTrack(for: track) != nil else {
            currentDecision = nil
            return
        }
        currentDecision = decision(for: track)
    }

    /// Measures the playing track now, and the next few in the queue a
    /// little later (so their decoding doesn't compete with this track's
    /// start), if they have no measurement yet.
    private func measureAhead(current: Track?) {
        lookaheadTask?.cancel()
        guard settings.enabled else { return }
        if let current { measureIfNeeded(current) }
        lookaheadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, let player = self.player else { return }
            for track in player.queue.prefix(self.lookahead) { self.measureIfNeeded(track) }
        }
    }

    private func measureIfNeeded(_ track: Track) {
        guard let analysis, let local = localTrack(for: track), measuredReading(local) == nil else { return }
        analysis.ensureAnalyzed(track)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
