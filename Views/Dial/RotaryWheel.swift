import AudioToolbox
import SwiftUI
import UIKit

/// Taptic Engine feedback for the dial, with generators kept prepared so
/// rapid spins stay crisp.
final class DialHaptics {
    private let detent = UISelectionFeedbackGenerator()
    private let press = UIImpactFeedbackGenerator(style: .rigid)
    private let endStop = UIImpactFeedbackGenerator(style: .heavy)
    var clickSound = false

    func prepare() {
        detent.prepare()
        press.prepare()
        endStop.prepare()
    }

    func tick() {
        detent.selectionChanged()
        detent.prepare()
        if clickSound { AudioServicesPlaySystemSound(1104) }
    }

    func pressed() {
        press.impactOccurred(intensity: 0.9)
        press.prepare()
        if clickSound { AudioServicesPlaySystemSound(1104) }
    }

    func bump() {
        endStop.impactOccurred(intensity: 1)
        endStop.prepare()
    }
}

/// A touch-sensitive rotary wheel: drag a finger around the ring and every
/// `detentDegrees` of travel fires `onStep(±1)` (clockwise = +1). The ring's
/// knurling turns with the finger. The centre is a separate button.
struct RotaryWheel: View {
    let accent: Color
    let haptics: DialHaptics
    /// Called per detent; return false if the step hit an end (heavier bump).
    let onStep: (Int) -> Bool
    let onCentre: () -> Void

    var detentDegrees: Double = 15

    @State private var lastAngle: Double?
    @State private var accumulated: Double = 0
    @State private var rotation: Double = 0
    @State private var bumpedAtEnd = false
    @State private var centrePressed = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outer = side / 2
            let inner = outer * 0.38
            ZStack {
                ring(outer: outer, inner: inner)
                    .frame(width: side, height: side)
                    .position(centre)
                    .contentShape(RingShape(innerRatio: 0.34), eoFill: true)
                    .gesture(spin(centre: centre, inner: inner * 0.9, outer: outer * 1.2))

                centreButton(diameter: inner * 2)
                    .position(centre)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { haptics.prepare() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dial")
        .accessibilityHint("Swipe up or down to turn. Double-tap to select.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = onStep(-1)
            case .decrement: _ = onStep(1)
            @unknown default: break
            }
        }
        .accessibilityAction { onCentre() }
    }

    // MARK: - Gesture

    private func spin(centre: CGPoint, inner: CGFloat, outer: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.location.x - centre.x
                let dy = value.location.y - centre.y
                let r = hypot(dx, dy)
                guard r > inner, r < outer else {
                    lastAngle = nil
                    return
                }
                let angle = atan2(Double(dy), Double(dx)) * 180 / .pi
                defer { lastAngle = angle }
                guard let last = lastAngle else { return }
                var delta = angle - last
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                rotation += delta
                accumulated += delta
                while accumulated >= detentDegrees {
                    accumulated -= detentDegrees
                    step(1)
                }
                while accumulated <= -detentDegrees {
                    accumulated += detentDegrees
                    step(-1)
                }
            }
            .onEnded { _ in
                lastAngle = nil
                accumulated = 0
                bumpedAtEnd = false
            }
    }

    private func step(_ delta: Int) {
        if onStep(delta) {
            bumpedAtEnd = false
            haptics.tick()
        } else if !bumpedAtEnd {
            // One firm bump at the end of a list, not one per detent.
            bumpedAtEnd = true
            haptics.bump()
        }
    }

    // MARK: - Drawing

    private func ring(outer: CGFloat, inner: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [Color(white: 0.13), Color(white: 0.06)],
                                   center: .center, startRadius: inner, endRadius: outer)
                )
            Circle()
                .stroke(Color(white: 0.22), lineWidth: 1)
            // Knurling: fine radial ridges that turn with the finger.
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r1 = outer * 0.80, r2 = outer * 0.95
                var ridges = Path()
                let count = 72
                for i in 0..<count {
                    let a = (Double(i) / Double(count)) * 2 * .pi
                    let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
                    ridges.move(to: CGPoint(x: c.x + ca * r1, y: c.y + sa * r1))
                    ridges.addLine(to: CGPoint(x: c.x + ca * r2, y: c.y + sa * r2))
                }
                context.stroke(ridges, with: .color(Color(white: 0.24)), lineWidth: 1)
                // Index mark.
                let ia = -Double.pi / 2
                let p = CGPoint(x: c.x + CGFloat(cos(ia)) * outer * 0.66,
                                y: c.y + CGFloat(sin(ia)) * outer * 0.66)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                             with: .color(accent))
            }
            .rotationEffect(.degrees(rotation))
            Circle()
                .stroke(Color.black, lineWidth: 2)
                .frame(width: inner * 2 + 6, height: inner * 2 + 6)
        }
    }

    private func centreButton(diameter: CGFloat) -> some View {
        Circle()
            .fill(
                LinearGradient(colors: centrePressed
                               ? [Color(white: 0.05), Color(white: 0.10)]
                               : [Color(white: 0.16), Color(white: 0.07)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(Circle().stroke(Color(white: 0.25), lineWidth: 1))
            .frame(width: diameter, height: diameter)
            .scaleEffect(centrePressed ? 0.97 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !centrePressed {
                            centrePressed = true
                            haptics.pressed()
                        }
                    }
                    .onEnded { _ in
                        centrePressed = false
                        onCentre()
                    }
            )
    }
}

/// Hit area for the ring only (hole in the middle for the centre button).
struct RingShape: Shape {
    let innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: rect)
        let inset = rect.width * (1 - innerRatio) / 2
        p.addEllipse(in: rect.insetBy(dx: inset, dy: inset))
        return p
    }
}
