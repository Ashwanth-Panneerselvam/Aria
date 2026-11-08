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
