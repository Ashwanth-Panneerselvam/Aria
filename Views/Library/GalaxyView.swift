import SwiftUI

/// The Galaxy: every analysed track is a star, placed so that tracks which
/// sound alike cluster together. Drag to drift, pinch to zoom, tap a star to
/// see it and its constellation of nearest neighbours, then play the star or
/// the whole neighbourhood.
///
/// Rendering is one `Canvas` (no per-star views), redrawn only on gestures
/// and selection changes — nothing animates while idle. Always a black sky,
/// whatever the app appearance.
struct GalaxyView: View {
    @EnvironmentObject private var analysisManager: LibraryAnalysisManager
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var selectedID: UUID?
    @State private var neighbourIDs: [UUID] = []

    private let neighbourCount = 19
    private let zoomRange: ClosedRange<CGFloat> = 0.7...14

    private var accent: Color { themeManager.theme.accentColor }
    private var stars: [LibraryAnalysisManager.GalaxyStar] { analysisManager.galaxy }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if stars.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    sky(size: geo.size)
                }
                .ignoresSafeArea(edges: .bottom)
                overlays
            }
            if analysisManager.isBuildingGalaxy {
                buildingBadge
            }
        }
        .navigationTitle("Galaxy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { analysisManager.buildGalaxyIfNeeded() }
        .onChange(of: analysisManager.isAnalyzingLibrary) { running in
            if !running { analysisManager.buildGalaxyIfNeeded() }
        }
        .onChange(of: analysisManager.galaxy) { _ in
            if let id = selectedID, !stars.contains(where: { $0.id == id }) { select(nil) }
        }
    }

    // MARK: - Geometry

    private var effectiveScale: CGFloat {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, zoom * pinch))
    }

    private var effectiveOffset: CGSize {
        let f = effectiveScale / zoom
        return CGSize(width: (pan.width + drag.width) * f, height: (pan.height + drag.height) * f)
    }

    private func baseRadius(_ size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.44
    }

    private func screenPoint(_ p: SIMD2<Double>, size: CGSize) -> CGPoint {
        let s = baseRadius(size) * effectiveScale
        let o = effectiveOffset
        return CGPoint(x: size.width / 2 + o.width + CGFloat(p.x) * s,
                       y: size.height / 2 + o.height + CGFloat(p.y) * s)
    }

    // MARK: - Sky

    private func sky(size: CGSize) -> some View {
        let nowPlayingID = playerManager.currentTrack.flatMap { LibraryAnalysisManager.localID(of: $0) }
        let neighbours = Set(neighbourIDs)
        return Canvas { context, canvasSize in
            let scale = effectiveScale
            let sizeBoost = min(2.2, max(1, sqrt(scale)))
            let hasSelection = selectedID != nil
            var points: [UUID: CGPoint] = [:]
            points.reserveCapacity(stars.count)

            // Constellation lines from the selected star to its neighbours.
            if let sel = selectedID, let selStar = stars.first(where: { $0.id == sel }) {
                let origin = screenPoint(selStar.position, size: canvasSize)
                var lines = Path()
                for star in stars where neighbours.contains(star.id) {
                    lines.move(to: origin)
                    lines.addLine(to: screenPoint(star.position, size: canvasSize))
                }
                context.stroke(lines, with: .color(accent.opacity(0.28)), lineWidth: 0.7)
            }

            for star in stars {
                let pt = screenPoint(star.position, size: canvasSize)
                points[star.id] = pt
                guard pt.x > -20, pt.y > -20, pt.x < canvasSize.width + 20, pt.y < canvasSize.height + 20 else {
                    continue
                }
                let r = (1.1 + 2.1 * CGFloat(star.energy)) * sizeBoost
                let emphasised = !hasSelection || star.id == selectedID || neighbours.contains(star.id)
                let color = Self.starColor(brightness: star.brightness)
                    .opacity(emphasised ? 0.95 : 0.28)
                context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(color))
            }

            // Now playing: an accent ring.
            if let id = nowPlayingID, let pt = points[id] {
                let r: CGFloat = 8 * sizeBoost
                context.stroke(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(accent), lineWidth: 1.5)
            }

            // Selection: a white ring.
            if let id = selectedID, let pt = points[id] {
                let r: CGFloat = 11 * sizeBoost
                context.stroke(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.white), lineWidth: 1)
            }

            // Names appear once zoomed in far enough to read them.
            if scale >= 2.6 {
                var drawn = 0
                for star in stars.sorted(by: { $0.energy > $1.energy }) {
                    guard drawn < 45, let pt = points[star.id],
                          pt.x > 0, pt.y > 0, pt.x < canvasSize.width, pt.y < canvasSize.height else { continue }
                    if hasSelection && star.id != selectedID && !neighbours.contains(star.id) { continue }
                    context.draw(
                        Text(star.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.7)),
                        at: CGPoint(x: pt.x + 6, y: pt.y),
                        anchor: .leading)
                    drawn += 1
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SimultaneousGesture(dragGesture, pinchGesture))
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in handleTap(at: value.location, size: size) }
        )
        .accessibilityElement()
        .accessibilityLabel("Galaxy of \(stars.count) tracks, arranged by how they sound")
        .accessibilityHint("Use the actions to play music from the map.")
        .accessibilityAction(named: "Play the neighbourhood of the playing track") {
            if let id = nowPlayingID { select(id); playNeighbourhood() }
        }
        .accessibilityAction(named: "Play a random neighbourhood") {
            if let star = stars.randomElement() { select(star.id); playNeighbourhood() }
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                let old = zoom
                let new = min(zoomRange.upperBound, max(zoomRange.lowerBound, old * value))
                zoom = new
                let f = new / old
                pan = CGSize(width: pan.width * f, height: pan.height * f)
            }
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        var best: (id: UUID, d: CGFloat)?
        for star in stars {
            let p = screenPoint(star.position, size: size)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d < 28, d < (best?.d ?? .infinity) { best = (star.id, d) }
        }
        if let best {
            Haptics.selection()
            select(best.id == selectedID ? nil : best.id)
        } else {
            select(nil)
        }
    }

    private func select(_ id: UUID?) {
        selectedID = id
        neighbourIDs = id.map { nearestNeighbours(of: $0) } ?? []
    }

    /// The k closest stars on the map, ordered as a walk outward from the
    /// selection (each next stop is the nearest unvisited one) so a
    /// neighbourhood plays as a smooth path rather than a random scatter.
    private func nearestNeighbours(of id: UUID) -> [UUID] {
        guard let origin = stars.first(where: { $0.id == id }) else { return [] }
        func dist(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            let d = a - b
            return d.x * d.x + d.y * d.y
        }
        let nearest = stars
            .filter { $0.id != id }
            .sorted { dist($0.position, origin.position) < dist($1.position, origin.position) }
            .prefix(neighbourCount)
        var remaining = Array(nearest)
        var path: [UUID] = []
        var current = origin.position
        while !remaining.isEmpty {
            let i = remaining.indices.min { dist(remaining[$0].position, current) < dist(remaining[$1].position, current) }!
            path.append(remaining[i].id)
            current = remaining[i].position
            remaining.remove(at: i)
        }
        return path
    }

    // MARK: - Playback

    private func playStar() {
        guard let id = selectedID else { return }
        let tracks = analysisManager.playerTracks(for: [id])
        guard !tracks.isEmpty else { return }
        playerManager.playSlice(tracks, startIndex: 0)
    }

    private func playNeighbourhood() {
        guard let id = selectedID else { return }
        let tracks = analysisManager.playerTracks(for: [id] + neighbourIDs)
        guard !tracks.isEmpty else { return }
        Haptics.success()
        playerManager.playSlice(tracks, startIndex: 0)
    }

    private func locateNowPlaying() {
        guard let track = playerManager.currentTrack,
              let id = LibraryAnalysisManager.localID(of: track),
              let star = stars.first(where: { $0.id == id }) else { return }
        // Centre on the star at a zoom where names are readable.
        let targetZoom: CGFloat = 3.2
        // The pan depends on the view size, so it's resolved in `overlays`
        // (which has the geometry) once `pendingCentre` is set.
        let change = { zoom = targetZoom }
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.45)) { change() } }
        pendingCentre = star.position
        select(id)
    }

    /// Set by `locateNowPlaying`; resolved to a pan once the view size is known.
    @State private var pendingCentre: SIMD2<Double>?

    // MARK: - Overlays

    private var overlays: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    VStack(spacing: DS.Spacing.sm) {
                        roundButton("scope", label: "Find the playing track") { locateNowPlaying() }
                            .disabled(playerManager.currentTrack == nil)
                        roundButton("arrow.down.right.and.arrow.up.left", label: "Reset view") {
                            let reset = { zoom = 1; pan = .zero }
                            if reduceMotion { reset() } else { withAnimation(.easeInOut(duration: 0.35)) { reset() } }
                        }
                    }
                }
                .padding(DS.Spacing.md)
                Spacer()
                if let id = selectedID, let star = stars.first(where: { $0.id == id }) {
                    selectionCard(star)
                        .padding(DS.Spacing.md)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    legend
                        .padding(DS.Spacing.md)
                }
            }
            .onChange(of: pendingCentre) { centre in
                guard let centre else { return }
                let s = baseRadius(geo.size) * zoom
                let target = CGSize(width: -CGFloat(centre.x) * s, height: -CGFloat(centre.y) * s)
                if reduceMotion { pan = target } else { withAnimation(.easeInOut(duration: 0.45)) { pan = target } }
                pendingCentre = nil
            }
        }
    }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(DesignTokens.OLED.elevated))
                .overlay(Circle().stroke(DesignTokens.OLED.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var legend: some View {
        HStack(spacing: DS.Spacing.md) {
            legendDot(Self.starColor(brightness: 0), "darker")
            legendDot(Self.starColor(brightness: 1), "brighter")
            Text("size = loudness")
            Spacer()
            Text("\(stars.count) stars")
        }
        .font(.system(size: 11))
        .foregroundColor(DesignTokens.OLED.textSecondary)
        .accessibilityHidden(true)
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }

    private func selectionCard(_ star: LibraryAnalysisManager.GalaxyStar) -> some View {
        let names = neighbourIDs.prefix(3).compactMap { id in stars.first(where: { $0.id == id })?.title }
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(star.title)
                        .font(DS.Typography.titleMedium)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(star.artist)
                        .font(DS.Typography.body)
                        .foregroundColor(DesignTokens.OLED.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { select(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DesignTokens.OLED.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            if !names.isEmpty {
                Text("Near: " + names.joined(separator: " · "))
                    .font(DS.Typography.caption)
                    .foregroundColor(DesignTokens.OLED.textDisabled)
                    .lineLimit(2)
            }
            HStack(spacing: DS.Spacing.sm) {
                Button(action: playStar) {
                    Label("Play", systemImage: "play.fill")
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().stroke(DesignTokens.OLED.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button(action: playNeighbourhood) {
                    Label("Neighbourhood · \(neighbourIDs.count + 1)", systemImage: "sparkles")
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .fill(DesignTokens.OLED.elevated))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .stroke(DesignTokens.OLED.border, lineWidth: 0.5))
    }

    private var buildingBadge: some View {
        VStack {
            HStack(spacing: DS.Spacing.sm) {
                ProgressView().tint(.white)
                Text("Mapping your library…")
                    .font(DS.Typography.caption)
                    .foregroundColor(DesignTokens.OLED.textSecondary)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
            .background(Capsule().fill(DesignTokens.OLED.elevated))
            .padding(.top, DS.Spacing.md)
            Spacer()
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(DesignTokens.OLED.textDisabled)
            Text("Your galaxy needs a map")
                .font(DS.Typography.titleMedium)
                .foregroundColor(.white)
            Text("Aria places every track by how it sounds — tempo, energy, brightness, bass, loudness and dynamics. That needs a one-time analysis of your library, done on this iPhone.")
                .font(DS.Typography.body)
                .foregroundColor(DesignTokens.OLED.textSecondary)
                .multilineTextAlignment(.center)
            if analysisManager.isAnalyzingLibrary {
                let p = analysisManager.progress
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .tint(accent)
                Text("Analysing \(p.done) of \(p.total)…")
                    .font(DS.Typography.caption)
                    .foregroundColor(DesignTokens.OLED.textSecondary)
            } else {
                Button {
                    analysisManager.analyzeLibrary()
                } label: {
                    Text("Analyse Library")
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(.black)
                        .frame(maxWidth: 260, minHeight: 50)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.xl)
    }

    // MARK: - Colour

    /// Warm amber for dark, bassy music → white → icy blue for bright music.
    static func starColor(brightness b: Double) -> Color {
        let warm = (r: 1.0, g: 0.66, b: 0.40)
        let mid = (r: 1.0, g: 0.97, b: 0.92)
        let cool = (r: 0.58, g: 0.80, b: 1.0)
        let t = max(0, min(1, b))
        if t < 0.5 {
            let k = t / 0.5
            return Color(red: warm.r + (mid.r - warm.r) * k,
                         green: warm.g + (mid.g - warm.g) * k,
                         blue: warm.b + (mid.b - warm.b) * k)
        }
        let k = (t - 0.5) / 0.5
        return Color(red: mid.r + (cool.r - mid.r) * k,
                     green: mid.g + (cool.g - mid.g) * k,
                     blue: mid.b + (cool.b - mid.b) * k)
    }
}
