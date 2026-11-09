# DAP v3 — analysis, crossfeed, tuning, radio, Wi-Fi transfer

Branch `feature/dap-v3` (on top of `feature/oled-dap-v2`). No change to the
library database, track IDs, import pipeline, bundle ID or entitlements.
New Info.plist key: `NSLocalNetworkUsageDescription` (Wi-Fi Transfer).

## Track analysis (shared engine)

- `Services/Analysis/TrackAnalyzer.swift` — one streaming decode
  (`AVAudioFile`, 32k-frame chunks) measuring: 240-bucket RMS waveform,
  sample peak, clipped runs, BS.1770 integrated loudness (K-weighting for any
  rate, 400 ms/75 % blocks, −70/−10 gates), DR score (3 s blocks, √2·RMS,
  top-20 % / 2nd peak), averaged 4096-pt spectrum (~160 Hann frames via vDSP)
  → spectral cutoff + sharpness, centroid, bass share; onset envelope →
  tempo + pulse clarity; padded-16-bit check for >16-bit sources.
- `TrackAnalysis` stores results; `QualityHint` turns them into worded
  heuristics (likely/possibly lossy source, likely upsampled, padded bit
  depth, clipping). Lossy files are never called transcodes.
- `LibraryAnalysisManager` — cache in `Documents/track_analysis.json`
  keyed by LocalTrack UUID, invalidated by file size or
  `TrackAnalysis.currentVersion`. Runs detached at utility priority, one file
  at a time, only on request (Library Audit, or the playing track for its
  waveform). Removed tracks are pruned on library runs.

## Features on top

- **Waveform seek bar** — `PlayerScrubber` draws `WaveformBars` when the
  playing track has analysis (toggle: More → DAP). Played part via mask; only
  the mask width changes per tick.
- **Library Audit** — More → DAP → Library Audit. Analyse/stop, progress,
  summary stats, per-track DR/LUFS, sortable, detail sheet with every
  measurement and the reasoning behind each hint.
- **Library Radio** — player radio button (local tracks). `LibraryRadio`
  z-scores six features (octave-folded tempo, pulse clarity, log centroid,
  bass share, LUFS, DR), picks among the 4 nearest to the previous track
  plus a pull toward the seed, no artist in the last two picks, max two per
  album. Replaces Up Next with 30 tracks.

## Post-EQ processing (`Services/DSP/DAPProcessor.swift`)

Runs inside `AudioEQTap.process` after the 10-band EQ (which AutoEQ fills),
whether or not EQ is on: headroom gain → up to 12 RBJ biquads → bs2b
crossfeed. Float32 non-interleaved only (the tap's format); anything else is
passed through. UI updates go through an unfair lock; the render thread uses
try-lock and preallocated storage — no waiting, no allocation.
`AVPlayerPath.updateDAP` attaches the tap when processing becomes active.

- **Crossfeed** — Gentle 650 Hz/9.5 dB (Meier), Natural 700/6.0 (Chu Moy),
  Strong 700/4.5 (bs2b default). Mono stays at unity.
- **Personal tuning** — bass shelf 105 Hz, warmth 250 Hz, presence 3 kHz,
  treble shelf 8 kHz.
- **Hearing profile** — `HearingCheckView` plays pulsed tones on a separate
  `AVAudioEngine` (raw IEM, no EQ) at 1k, 2k, 4k, 8k, 500, 250, 125 Hz,
  −30 dBFS stepping −3 dB per 0.7 s pulse until the listener taps. Deviation =
  (threshold − 1 kHz threshold) − ISO 226 typical relative threshold;
  correction = deviation × strength (default 50 %), capped +6/−3 dB, Q 1.2.
  Not a medical test, labelled as such.
- Headroom = −(max combined filter response 20 Hz–20 kHz).
- Settings: `SoundProcessingManager`, UserDefaults `sound_processing_v1`.

## Wi-Fi Transfer

- `TransferServerCore` — `NWListener` (`acceptLocalOnly`), port 8080 or any.
  `GET /` page, `GET /api/ping`, `GET /api/library`, `PUT /upload`.
  6-digit PIN per session (`X-Aria-Pin`), constant-time compare, stops after
  20 wrong PINs. Uploads stream to `tmp/WiFiInbox/<uuid>/`, size/space/
  extension checked first, imported via `LocalLibraryManager.importFile`,
  then deleted. Same size + extension as an existing track ⇒ skipped.
- `WiFiTransferServer` (main actor) — state, PIN, en0 IPv4, upload list.
- `WiFiTransferView` — runs only while visible; keeps the screen awake while
  serving; stops on background. Entry: Library “+” menu and More → DAP.
- `TransferPage` — self-contained HTML/JS: PIN gate, drag files/folders
  (recursive), sequential XHR uploads with progress.

## Tests

`DAPProcessingTests`, `TrackAnalyzerTests` (synthesised WAVs: sine loudness/
peak/DR, band-limited transcode signature, full-band noise, padded bit
depth, 120 BPM click track), `LibraryRadioAndTransferTests`.

## Galaxy

- `Services/Analysis/GalaxyLayout.swift` — exact t-SNE (perplexity ≤ 30,
  PCA init, 12× early exaggeration for the first third, momentum + gains)
  on the six Library Radio features, z-scored and weighted. Deterministic.
  ≤ 1 500 tracks (500 iterations above 800); larger libraries use PCA only.
  Output normalised to ±1 (99th-percentile radius).
- `LibraryAnalysisManager.buildGalaxyIfNeeded()` — detached build, keyed by
  the set of analysed tracks (id, version, size); rebuilt after a library
  analysis run finishes. Star colour = rank of spectral centroid (amber →
  white → blue), size = rank of integrated loudness.
- `Views/Library/GalaxyView.swift` — single `Canvas`; drag/pinch/tap
  (`SpatialTapGesture`), selection draws lines to the 19 nearest stars;
  "Neighbourhood" plays them as a nearest-next walk. Now playing = accent
  ring; "scope" button flies to it. Titles appear at zoom ≥ 2.6 (max 45).
  Always black. Entry: Library toolbar ✦ and More → DAP → Galaxy.
- Tests: `GalaxyLayoutTests` (range, cluster preservation, determinism,
  tiny and degenerate inputs).

## Pet

- `PetStore` (UserDefaults `pet_v1`): listening days → stage (baby < 3 days,
  kid < 10, grown); per-session play counts → mood (sleeping when paused,
  excited for 8 s on a track's first play this session, bored from the 3rd
  play, otherwise dancing). Fed from `ContentView` on track change.
- `PetView`: 14×12 pixel sprite on a `Canvas` inside `TimelineView`
  (12 fps while playing, 2 fps asleep, paused under Reduce Motion). Bob
  rate = analysed tempo folded into 70–150 BPM (tempo-matched, not
  beat-phase-locked). Tap for a thought bubble. Toggle: More → DAP → Pet.

## ABX challenge

- `ABXClipMaker`: 15 s excerpt (44.1/48 kHz sources only) → 10 ms edge fades
  → AAC via `AVAudioFile` at 128/192/256/320 kbps → decode → cross-
  correlation alignment (±4096 samples) → RMS level match. `ABXStats` gives
  the one-sided binomial p-value.
- `ABXSession`: own `AVAudioEngine`/`AVAudioPlayerNode` (no EQ on either
  version); switching keeps the playhead (slice + looping buffer). 16
  trials, new random X each. Verdict at p < 0.01 / < 0.05.
- Entry: More → DAP → ABX Challenge.

## Dial mode

Original retro design (not a replica of any product): black body, amber /
green / ice dot-matrix screen, knurled dial, four keys.

- `DialNavigator`: stack of menu / now playing / message screens; inputs
  rotate(±n) (returns false at list ends), select, back, play/pause,
  next/previous. Now Playing: wheel seeks ±5 s per detent, centre = play/pause.
- `DialController`: menu tree — Now Playing, Artists → albums → songs,
  Albums, Songs, Playlists, Favourites, Shuffle All, Library Radio, Display
  (screen colour, click sound), Exit. Album order by file name.
- `RotaryWheel`: drag around the ring (even-odd hit area), 15° per detent
  → `UISelectionFeedbackGenerator` tick; one heavy bump at a list end;
  rigid impact on centre and keys; optional system click sound. Knurling
  rotates with the finger. VoiceOver: adjustable action + default action.
- `Dither`: Atkinson 1-bit dithering of the artwork at 40×40.
- Interface setting, not a modal: `InterfaceMode` (`standard | dial`,
  UserDefaults `interface_mode`, unknown → standard) on `SettingsManager`.
  `ContentView` swaps the whole tab UI for `DialModeView` (cross-fade,
  none under Reduce Motion); lifecycle modifiers sit on the outer body so
  they run in either interface. Switch: More → Appearance → Interface,
  More → DAP → Switch to Dial; back via the Dial's STANDARD key or its
  "Standard Interface" menu item. Restored on launch.

Tests: `PetABXDialTests`.

## Tag reading fix (FLAC)

AVFoundation's `commonMetadata` doesn't expose FLAC Vorbis comments, so FLAC
imports stored the file name as title, "This Device" as artist and no album.

- `Services/AudioTags.swift` parses METADATA_BLOCK_VORBIS_COMMENT directly
  (ID3v2-prefixed files supported; other blocks such as PICTURE are skipped
  by seeking). Keys are case-insensitive; multiple ARTIST values are joined;
  ALBUMARTIST is the artist fallback; TRACKNUMBER/DISCNUMBER "n/m" → n.
  Non-FLAC files fall back to AVFoundation's per-format metadata.
- Import: tags fill anything common metadata missed.
- `LocalLibraryManager.repairTagsFromFiles()`: for tracks with a placeholder
  artist or no album, fills only those fields (and the title when the
  artist was a placeholder, i.e. tags were never read). Ids, file names,
  artwork, dates and sizes unchanged. Writes
  `Documents/AriaLibrary-before-tag-repair.json` once before the first change.
- `LibraryTagRepair` runs it once at launch (`library_tag_repair_v1`) and on
  demand (Library Audit → Tags → Re-read from files), then refreshes the
  track copies stored in playlists and favourites.
- Dial: albums grouped by name (compilations stay whole, detail = artist or
  "Various"); album tracks ordered by disc/track tags read on demand.
- Galaxy rebuild key now includes title/artist.
- Tests: `AudioTagsTests`.

## Metadata Doctor

Edits Aria's library list only — never the audio files.

- `Services/MetadataDoctor.swift` (pure): name key = case/diacritic/width
  folded, "&"→"and", leading "The " dropped, non-alphanumerics removed.
  Variant groups = >1 spelling per key; suggestion = most tracks, ties to
  the more styled spelling. Title tidy: underscores (only when no spaces),
  leading track numbers ("01 - ", "03.", "7)"; a dash needs a following
  space so "2-Step" survives; "." must precede a letter so "3.14" survives),
  bracketed junk ("Official Audio", "Lyrics", "HD", …), spacing. Artwork:
  tracks without a cover whose album key has a covered track (same artist
  preferred). Split from title: "Title – Artist – Album" / "Artist –
  Title" / "Title – Artist" on " - ", " – ", " — " (spaces required);
  likely pattern pre-selected.
- `LocalLibraryManager.applyMetadataEdits` / `restoreMetadata`: only title,
  artist, album, artwork change; artwork is copied to the target's own file.
  Backup `Documents/AriaLibrary-before-metadata-doctor.json` once.
- `MetadataDoctorModel`: scan, apply, undo of the last batch (UserDefaults
  `metadata_doctor_undo_v1`), propagation to playlists/favourites via
  `LibraryTagRepair.propagate`.
- `Views/More/MetadataDoctorView.swift`: overview, preview screens with
  per-item ticks, Undo card, "still missing" counts with Re-read tags and
  Split from titles. Entry: More → DAP, and Library Audit → Tags.
- Tests: `MetadataDoctorTests`.
