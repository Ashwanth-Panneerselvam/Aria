import SwiftUI

/// The pet on the Now Playing screen: a small pixel creature drawn on a
/// `Canvas`. It animates only while music plays (12 fps, tempo-matched bob)
/// or slowly while asleep (2 fps for the floating z's), and holds still with
/// Reduce Motion. Tap it for a thought bubble.
struct PetView: View {
    @EnvironmentObject private var petStore: PetStore
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var analysisManager: LibraryAnalysisManager
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bubble: String?
    @State private var hopAt: Date?

    static let pixel: CGFloat = 2.5
    static let gridWidth = 14
    static let gridHeight = 12

    private var bpm: Double {
        var b = playerManager.currentTrack.flatMap { analysisManager.analysis(for: $0)?.features.tempoBPM } ?? 100
        while b > 150 { b /= 2 }
        while b < 70 { b *= 2 }
        return b
    }

    var body: some View {
        let isPlaying = playerManager.isPlaying
        let interval: Double = isPlaying ? 1.0 / 12.0 : 0.5
        TimelineView(.animation(minimumInterval: interval, paused: reduceMotion)) { timeline in
            let now = timeline.date
            let mood = petStore.mood(isPlaying: isPlaying, now: now)
            Canvas { context, size in
                PetSprite.draw(in: &context, size: size, mood: mood, stage: petStore.stage,
                               time: reduceMotion ? 0 : now.timeIntervalSinceReferenceDate,
                               bpm: bpm, hopAt: hopAt.map { now.timeIntervalSince($0) },
                               body: .white.opacity(0.92), accent: themeManager.theme.accentColor)
            }
            .frame(width: CGFloat(Self.gridWidth) * Self.pixel + 10,
                   height: CGFloat(Self.gridHeight) * Self.pixel + 8)
            .accessibilityElement()
            .accessibilityLabel("Pet, \(petStore.stage.label), \(Self.moodWord(mood))")
            .accessibilityHint("Double-tap to see what it thinks.")
            .accessibilityAddTraits(.isButton)
        }
        .overlay(alignment: .top) {
            if let bubble {
                Text(bubble)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white))
                    .offset(y: -26)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { poke() }
    }

    private func poke() {
        Haptics.light()
        hopAt = Date()
        let text: String
        switch petStore.mood(isPlaying: playerManager.isPlaying) {
        case .sleeping: text = "zzz…"
        case .excited: text = "ooh, a new one!"
        case .bored: text = "this one… again?"
        case .dancing: text = "♪ \(Int(bpm.rounded())) BPM"
        }
        if reduceMotion { bubble = text } else { withAnimation(.easeOut(duration: 0.15)) { bubble = text } }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if reduceMotion { bubble = nil } else { withAnimation(.easeIn(duration: 0.2)) { bubble = nil } }
        }
    }

    static func moodWord(_ mood: PetStore.Mood) -> String {
        switch mood {
        case .sleeping: return "asleep"
        case .dancing: return "dancing"
        case .excited: return "excited"
        case .bored: return "bored"
        }
    }
}

/// Pixel-art drawing for the pet. A 14 × 12 grid; '#' is body.
enum PetSprite {
    // Body silhouette, rows 2…10 of the grid (antennae occupy rows 0–1).
    static let bodyRows: [String] = [
        ".....####.....",
        "...########...",
        "..##########..",
        ".############.",
        ".############.",
        ".############.",
        "..##########..",
        "...########...",
        "...##....##...",
    ]

    static func draw(in context: inout GraphicsContext, size: CGSize, mood: PetStore.Mood,
                     stage: PetStore.Stage, time t: Double, bpm: Double, hopAt: Double?,
                     body: Color, accent: Color) {
        let p = PetView.pixel
        let scale: CGFloat = stage == .baby ? 0.8 : 1
        let px = p * scale
        let gridW = CGFloat(PetView.gridWidth) * px
        let gridH = CGFloat(PetView.gridHeight) * px
        let originX = (size.width - gridW) / 2
        var originY = size.height - gridH - 2

        // Motion.
        let beat = t * bpm / 60
        var lean: CGFloat = 0
        switch mood {
        case .dancing:
            originY -= CGFloat(abs(sin(beat * .pi))) * px
            lean = sin(beat * .pi) >= 0 ? px : -px
        case .excited:
            originY -= CGFloat(abs(sin(t * 7))) * 2 * px
        case .bored, .sleeping:
            originY += CGFloat(sin(t * 0.9)) * 0.4 * px   // slow breathing
        }
        if let since = hopAt, since < 0.35 {
            originY -= CGFloat(sin(since / 0.35 * .pi)) * 4 * px
        }

        func fill(_ col: Int, _ row: Int, _ color: Color, leanTop: Bool = false) {
            let shift = leanTop && row < 6 ? lean : 0
            let rect = CGRect(x: originX + CGFloat(col) * px + shift,
                              y: originY + CGFloat(row) * px,
                              width: px + 0.3, height: px + 0.3)
            context.fill(Path(rect), with: .color(color))
        }
        let hole = Color.black

        // Antennae.
        if stage >= .kid {
            fill(4, 1, body, leanTop: true); fill(3, 0, accent, leanTop: true)
        }
        if stage == .grown {
            fill(9, 1, body, leanTop: true); fill(10, 0, accent, leanTop: true)
        }

        // Body.
        for (r, line) in bodyRows.enumerated() {
            for (c, ch) in line.enumerated() where ch == "#" {
                fill(c, r + 2, body, leanTop: true)
            }
        }

        // Eyes (cut out of the body).
        let blink = t > 0 && mood != .sleeping && (t.truncatingRemainder(dividingBy: 4.2)) < 0.12
        switch mood {
        case .sleeping:
            for c in [4, 5, 8, 9] { fill(c, 7, hole, leanTop: true) }
        case .bored:
            for c in [4, 5, 8, 9] { fill(c, 7, hole, leanTop: true) }
            for c in 5...8 { fill(c, 9, hole) }
        default:
            if blink {
                for c in [4, 5, 8, 9] { fill(c, 7, hole, leanTop: true) }
            } else {
                for c in [4, 5, 8, 9] { for r in [6, 7] { fill(c, r, hole, leanTop: true) } }
                if mood == .excited {
                    fill(4, 6, body, leanTop: true); fill(8, 6, body, leanTop: true) // sparkle in the eye
                }
            }
            if mood == .excited {
                for c in [6, 7] { for r in [8, 9] { fill(c, r, hole) } }  // open mouth
            } else {
                fill(6, 9, hole); fill(7, 9, hole)
            }
        }

        // Extras.
        switch mood {
        case .sleeping:
            let phase = Int(t * 2) % 3
            let zs = ["z", "z", "Z"]
            for i in 0...phase {
                context.draw(Text(zs[i]).font(.system(size: 7 + CGFloat(i) * 2, weight: .bold))
                                .foregroundColor(.white.opacity(0.75)),
                             at: CGPoint(x: originX + gridW - 2 + CGFloat(i) * 4,
                                         y: originY + 6 - CGFloat(i) * 6))
            }
        case .excited:
            let k = Int(t * 6) % 2
            for (dx, dy) in [(-2, 3), (15, 2), (-1, 9), (15, 8)].enumerated().filter({ $0.offset % 2 == k }).map({ $0.element }) {
                fill(dx, dy, accent)
            }
        default:
            break
        }
    }
}
