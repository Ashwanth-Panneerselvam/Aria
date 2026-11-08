# OLED DAP Mode v2 — implementation note

Branch: `feature/oled-dap-v2`. UI/appearance work only: no changes to
`PlayerManager`, `AVPlayerPath`, the EQ tap, `EQController`, AutoEQ data,
library storage, track identifiers, bundle ID, entitlements or Info.plists.

## Appearance model

- `Models/AppearanceMode.swift` — `light | dark | oled` (raw values are the
  persisted strings). Single typed source of truth.
- Persisted by `SettingsManager.appearanceMode` under `appearance_mode`.
- Migration (`AppearanceMode.resolve`): typed value wins → else the legacy
  `dark_mode` Bool (true → Dark, false → Light) → else Dark. Unknown typed
  values fall back the same way. Nothing is deleted.
- `dark_mode` is still written (true for Dark and True Black) so installing an
  older build over this one keeps a sensible choice.
- `ThemeManager.appearance` is the published runtime copy; it is written only
  via `ThemeManager.setAppearance(_:)`, which persists through
  `SettingsManager.setAppearance(_:)`. Same pattern as the accent theme.
  `isDarkMode` is now derived, not stored.
- True Black maps to `ColorScheme.dark` (`.preferredColorScheme` at the root),
  so pickers, alerts, keyboards and share sheets use the system dark style.

## Tokens

`DesignTokens(appearance:accent:)` (the v1 `init(isDark:accent:)` remains).
Light/Dark values are byte-for-byte the v1 values. OLED palette lives in
`DesignTokens.OLED`: `#000000` background, `#0E0E0E` surface/card,
`#151515` elevated, `#242424` divider/hairline, `#FFFFFF` / `#A8A8A8` /
`#707070` text. New tokens: `elevatedSurface`, `chromeBackground`,
`chromeBorder`, `textDisabled`, `isOLED`.

Because every screen already draws from tokens, Library, Favorites,
Playlists, Search, More, Queue, EQ, Speed/Pitch and the AutoEQ browser pick up
OLED automatically. Explicit OLED-only changes:

- `ariaNavigationBar()` (DesignSystem.swift): opaque black nav bar in OLED;
  Light/Dark keep `Material.bar` + automatic visibility (v1 behaviour).
- Custom tab bar: black + top hairline.
- Mini player, add-to-queue toast, import banner, error banner: solid
  surfaces instead of `.ultraThinMaterial` (materials kept in Light/Dark).
- Artwork placeholder: dim tile instead of a bright grey square.

## Player

- `FullScreenPlayerView`: header (close · ARIA · queue), artwork sized from
  `GeometryReader` (column width capped at ~39–42 % of height; 30 % and a
  scrolling column at Dynamic Type ≥ xxLarge), title + "Artist — Album",
  scrubber, transport (shuffle · prev · play disc · next · repeat), secondary
  row (favourite · download for streamed tracks · add to playlist · EQ pill ·
  speed/pitch · share), optional audio strip, polished empty state.
  Pull-to-dismiss is attached to header + artwork only.
- `PlayerScrubber` is the only full-player view observing `PlaybackClock`
  (previously the whole player re-rendered at 4 Hz). Seeks on release;
  VoiceOver adjustable ±10 s; shows "Buffering…" instead of a remaining time
  while loading/rebuffering.
- `MiniPlayerView`: 56 pt, artwork/title button separate from play/next
  buttons; `MiniProgressLine` alone observes the clock.

## Audio info strip

`Services/AudioSourceInfo.swift` reads the file header (`AVAudioFile`) off the
main thread, cached per path. FLAC/ALAC bit depth comes from the
`kAppleLosslessFormatFlag_*BitSourceData` flags; PCM from
`mBitsPerChannel`; lossy codecs show no bit depth. m4a is classified by
format ID, not extension. Line 1 = source file facts; line 2 = EQ state,
"Tuned" when speed/pitch ≠ default, output route, and the audio session's
sample rate labelled "out". It never claims bit-perfect output or a DAC word
length. Toggle: More → Extras → Audio Info Strip (`show_audio_info_strip`).

## Lock screen (NowPlayingService)

- Artwork is tagged with its track ID and only attached to that track's info.
  Fixes: a track without a cover kept the previous track's art.
- In-flight loads for a previous track are cancelled; results are applied
  only if the track is still current.
- File read + decode moved off the main actor; ImageIO downsampling to
  1024 px; aspect-fit resize in a nonisolated handler (the system calls it on
  a background queue).
- Cold-restored sessions now get artwork on the first update.
- Album title added (`MPMediaItemPropertyAlbumTitle`).
- Play/Pause remote commands are no longer both toggles: Pause while paused
  (e.g. after a DAC is unplugged) no longer starts playback.
- Unchanged and verified by reading: elapsed/duration/rate, explicit
  `playbackState`, next/previous enablement, seek command, Like command,
  interruption and `oldDeviceUnavailable` handling in `PlayerManager`,
  `UIBackgroundModes = audio`, `.playback` / `.longFormAudio` session.

The system lock-screen layout, background and clock are not modifiable by
apps. A pure-black wallpaper is the closest visual match. A WidgetKit /
Live Activity extension was not added: it would duplicate the system Now
Playing controls and needs an extra target, App Group and signing that a
free sideloading account handles poorly.

## Tests

`Tests/AppearanceModeTests.swift` (migration, persistence, rollback key,
live switching, accent preserved, OLED palette, contrast) and
`Tests/AudioSourceInfoTests.swift` (header → display mapping, no guessed
bit depth, sample-rate and time formatting).
