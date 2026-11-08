import SwiftUI

/// Dial mode: Aria as a little retro player — a monochrome dot-matrix
/// screen, a touch-sensitive rotary wheel with haptic detents, a centre
/// select button and four keys. Full screen, black, one-handed.
///
/// Wheel: scroll menus (on Now Playing: seek ±5 s per click).
/// Centre: select (on Now Playing: play/pause).
/// Keys: Back · Previous · Play/Pause · Next.
struct DialModeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var libraryManager: LocalLibraryManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var analysisManager: LibraryAnalysisManager

    @StateObject private var controller = DialController()

    var body: some View {
        DialDevice(navigator: controller.navigator, onExit: { dismiss() })
            .onAppear {
                controller.configure(library: libraryManager, playlists: playlistsManager,
                                     favorites: favoritesManager, player: playerManager,
                                     analysis: analysisManager)
            }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
    }
}

private struct DialDevice: View {
    @ObservedObject var navigator: DialNavigator
    let onExit: () -> Void

    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager
    @AppStorage(DialLCDColor.storageKey) private var colourRaw = DialLCDColor.amber.rawValue
    @AppStorage(DialLCDColor.clickSoundKey) private var clickSound = false

    @State private var haptics = DialHaptics()

    private var palette: LCDPalette { LCDPalette(DialLCDColor(rawValue: colourRaw) ?? .amber) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let screenHeight = min(geo.size.height * 0.36, w * 0.82)
            let wheelSide = min(w - 72, geo.size.height * 0.40, 300)
            VStack(spacing: 0) {
                HStack {
                    Button(action: onExit) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(white: 0.45))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Exit dial mode")
                    Spacer()
                }
                .padding(.horizontal, 8)

                DialLCD(navigator: navigator, palette: palette)
                    .frame(width: w - 40, height: screenHeight)

                Spacer(minLength: 16)

                RotaryWheel(accent: palette.ink, haptics: haptics,
                            onStep: { delta in navigator.rotate(delta) },
                            onCentre: { navigator.select() })
                    .frame(width: wheelSide, height: wheelSide)

                Spacer(minLength: 14)

                keys
                    .frame(width: min(w - 48, 320))

                Spacer(minLength: 20)
            }
            .frame(width: w, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            haptics.clickSound = clickSound
            haptics.prepare()
        }
        .onChange(of: clickSound) { haptics.clickSound = $0 }
        .onChange(of: navigator.exitRequested) { if $0 { onExit() } }
        .onChange(of: playerManager.currentTrack?.id) { _ in navigator.reloadMenus() }
    }

    private var keys: some View {
        HStack(spacing: 12) {
            key("BACK", systemImage: nil, label: "Back") {
                if !navigator.back() { haptics.bump() }
            }
            key(nil, systemImage: "backward.fill", label: "Previous track") { navigator.previous() }
            key(nil, systemImage: playerManager.isPlaying ? "pause.fill" : "play.fill",
                label: playerManager.isPlaying ? "Pause" : "Play") { navigator.playPause() }
            key(nil, systemImage: "forward.fill", label: "Next track") { navigator.next() }
        }
    }

    private func key(_ text: String?, systemImage: String?, label: String,
                     action: @escaping () -> Void) -> some View {
        Button {
            haptics.pressed()
            action()
        } label: {
            Group {
                if let text {
                    Text(text).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundColor(Color(white: 0.75))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(Color(white: 0.09)))
            .overlay(Capsule().stroke(Color(white: 0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Screen

struct LCDPalette {
    let ink: Color
    let glass: Color
    let dim: Color

    init(_ colour: DialLCDColor) {
        switch colour {
        case .amber:
            ink = Color(red: 1.0, green: 0.69, blue: 0.20)
            glass = Color(red: 0.06, green: 0.035, blue: 0.0)
        case .green:
            ink = Color(red: 0.42, green: 1.0, blue: 0.55)
            glass = Color(red: 0.0, green: 0.05, blue: 0.02)
        case .ice:
            ink = Color(red: 0.62, green: 0.86, blue: 1.0)
            glass = Color(red: 0.0, green: 0.03, blue: 0.06)
        }
        dim = ink.opacity(0.45)
    }
}

private struct DialLCD: View {
    @ObservedObject var navigator: DialNavigator
    let palette: LCDPalette

    static let font = Font.system(size: 15, weight: .semibold, design: .monospaced)
    static let smallFont = Font.system(size: 11, weight: .semibold, design: .monospaced)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.glass)
            Group {
                switch navigator.top {
                case .menu(let menu):
                    MenuScreen(title: menu.title, items: menu.items, selection: menu.selection, palette: palette)
                case .nowPlaying:
                    NowPlayingScreen(navigator: navigator, palette: palette)
                case .message(let text):
                    VStack(spacing: 8) {
                        Text(text).font(Self.font).foregroundColor(palette.ink).multilineTextAlignment(.center)
                        Text("press any key").font(Self.smallFont).foregroundColor(palette.dim)
                    }
                    .padding()
                }
            }
            .padding(10)
            PixelGrid().allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(white: 0.16), lineWidth: 3))
    }
}

/// Faint dot-matrix texture over the screen.
private struct PixelGrid: View {
    var body: some View {
        Canvas { context, size in
            var p = Path()
            var x: CGFloat = 0
            while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += 3 }
            var y: CGFloat = 0
            while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += 3 }
            context.stroke(p, with: .color(.black.opacity(0.35)), lineWidth: 0.6)
        }
        .accessibilityHidden(true)
    }
}

private struct LCDHeader: View {
    let title: String
    let trailing: String
    let palette: LCDPalette

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 6)
                Text(trailing).lineLimit(1)
            }
            .font(DialLCD.smallFont)
            .foregroundColor(palette.ink)
            Rectangle().fill(palette.dim).frame(height: 1)
        }
    }
}

private struct MenuScreen: View {
    // Values, not the `DialMenu` reference, so SwiftUI sees every change.
    let title: String
    let items: [DialItem]
    let selection: Int
    let palette: LCDPalette
    @EnvironmentObject private var playerManager: PlayerManager

    private let rowHeight: CGFloat = 25

    var body: some View {
        VStack(spacing: 4) {
            LCDHeader(title: title.uppercased(),
                      trailing: (playerManager.isPlaying ? "▶ " : "") + Self.clock(),
                      palette: palette)
            GeometryReader { geo in
                let visible = max(1, Int(geo.size.height / rowHeight))
                let count = items.count
                let first = max(0, min(selection - visible / 2, count - visible))
                let last = min(count, first + visible)
                HStack(spacing: 4) {
                    VStack(spacing: 0) {
                        ForEach(first..<max(first, last), id: \.self) { i in
                            row(items[i], selected: i == selection)
                        }
                        Spacer(minLength: 0)
                    }
                    if count > visible {
                        scrollBar(first: first, visible: visible, count: count, height: geo.size.height)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard items.indices.contains(selection) else { return title }
        let item = items[selection]
        return "\(title). \(item.title)\(item.detail.map { ", \($0)" } ?? ""). \(selection + 1) of \(items.count)."
    }

    private func row(_ item: DialItem, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(DialLCD.font)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let detail = item.detail {
                Text(detail)
                    .font(DialLCD.smallFont)
                    .lineLimit(1)
                    .opacity(selected ? 0.8 : 0.6)
            }
            if item.opensSomething {
                Text("›").font(DialLCD.font)
            }
        }
        .foregroundColor(selected ? palette.glass : palette.ink)
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background(selected ? palette.ink : Color.clear)
    }

    private func scrollBar(first: Int, visible: Int, count: Int, height: CGFloat) -> some View {
        let thumb = max(10, height * CGFloat(visible) / CGFloat(count))
        let travel = height - thumb
        let offset = count > visible ? travel * CGFloat(first) / CGFloat(count - visible) : 0
        return ZStack(alignment: .top) {
            Rectangle().fill(palette.dim.opacity(0.4)).frame(width: 3)
            Rectangle().fill(palette.ink).frame(width: 3, height: thumb).offset(y: offset)
        }
        .frame(width: 3, height: height)
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}

private struct NowPlayingScreen: View {
    @ObservedObject var navigator: DialNavigator
    let palette: LCDPalette
    @EnvironmentObject private var playerManager: PlayerManager

    @State private var art: [Bool]?
    static let artPixels = 40

    var body: some View {
        VStack(spacing: 6) {
            LCDHeader(title: "NOW PLAYING", trailing: positionText, palette: palette)
            if let track = playerManager.currentTrack {
                HStack(alignment: .top, spacing: 10) {
                    DitheredArt(bits: art, side: Self.artPixels, palette: palette)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(DialLCD.font).lineLimit(2)
                        Text(track.artist).font(DialLCD.smallFont).lineLimit(1).opacity(0.8)
                        if let album = track.album, !album.isEmpty {
                            Text(album).font(DialLCD.smallFont).lineLimit(1).opacity(0.6)
                        }
                    }
                    .foregroundColor(palette.ink)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                LCDProgress(palette: palette, seekHint: seekHint)
            } else {
                Spacer()
                Text("nothing playing").font(DialLCD.font).foregroundColor(palette.dim)
                Spacer()
            }
        }
        .task(id: playerManager.currentArtworkURL) {
            art = nil
            guard let url = playerManager.currentArtworkURL else { return }
            let side = Self.artPixels
            let bits = await Task.detached(priority: .utility) {
                await Dither.load(url: url, side: side)
            }.value
            if !Task.isCancelled { art = bits }
        }
        .accessibilityElement(children: .combine)
    }

    private var positionText: String {
        let state = playerManager.isPlaying ? "▶" : "❚❚"
        let upNext = playerManager.queue.count
        return upNext > 0 ? "\(state) +\(upNext)" : state
    }

    private var seekHint: String? {
        guard let seek = navigator.lastSeek, Date().timeIntervalSince(seek.at) < 0.8 else { return nil }
        return seek.delta > 0 ? "»" : "«"
    }
}

/// 1-bit album art: lit pixels in ink, the rest glass.
private struct DitheredArt: View {
    let bits: [Bool]?
    let side: Int
    let palette: LCDPalette

    var body: some View {
        Canvas { context, size in
            guard let bits, bits.count == side * side else {
                context.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)),
                               with: .color(palette.dim), lineWidth: 1)
                context.draw(Text("♪").font(.system(size: 24, design: .monospaced)).foregroundColor(palette.dim),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let px = size.width / CGFloat(side)
            var lit = Path()
            for y in 0..<side {
                for x in 0..<side where bits[y * side + x] {
                    lit.addRect(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px))
                }
            }
            context.fill(lit, with: .color(palette.ink))
        }
        .accessibilityHidden(true)
    }
}

/// Segmented progress bar + times; the only part observing the clock.
private struct LCDProgress: View {
    @EnvironmentObject private var clock: PlaybackClock
    let palette: LCDPalette
    let seekHint: String?

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let segments = max(10, Int(geo.size.width / 5))
                let fraction = clock.duration > 0 ? min(1, max(0, clock.currentTime / clock.duration)) : 0
                let filled = Int((Double(segments) * fraction).rounded(.down))
                HStack(spacing: 1) {
                    ForEach(0..<segments, id: \.self) { i in
                        Rectangle().fill(i < filled ? palette.ink : palette.dim.opacity(0.35))
                    }
                }
            }
            .frame(height: 8)
            HStack {
                Text(PlayerScrubber.format(clock.currentTime))
                Spacer()
                if let seekHint { Text(seekHint) }
                Spacer()
                Text(clock.duration > 0 ? "-" + PlayerScrubber.format(max(0, clock.duration - clock.currentTime)) : "--:--")
            }
            .font(DialLCD.smallFont.monospacedDigit())
            .foregroundColor(palette.ink)
        }
    }
}
