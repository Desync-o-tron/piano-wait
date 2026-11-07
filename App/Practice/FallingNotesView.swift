import PianoWaitCore
import SwiftUI

/// Note bars falling toward the keyboard, colored by hand, with a glow on the notes being waited for.
struct FallingNotesView: View {
    /// Dragging this far starts a pan, so that a pinch's first finger does not.
    private static let minimumPanDistance = 10.0

    let session: PracticeSession
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @GestureState private var appliedPan: CGFloat?
    @State private var isPinching = false
    @State private var viewWidth = CGFloat.zero

    var body: some View {
        Canvas { context, size in
            drawBackdrop(in: &context, size: size)
            drawGuides(in: &context, size: size)
            drawLoop(in: &context, size: size)
            drawNotes(in: &context, size: size)
            drawHitLine(in: &context, size: size)
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { viewWidth = $0 }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: Self.minimumPanDistance)
                .updating($appliedPan) { value, applied, _ in
                    let step = value.translation.width - (applied ?? 0)
                    applied = value.translation.width
                    guard !isPinching, viewWidth > 0 else { return }
                    session.zoom.keyboard = session.zoom.keyboard.panned(by: -step / viewWidth)
                }
        )
        .pinchToZoomKeyboard(session: session) { isPinching = $0 }
        .accessibilityElement()
        .accessibilityLabel("Falling notes")
        .accessibilityValue(session.waitingNotes.sorted().map(MIDINote.name).joined(separator: ", "))
        .accessibilityIdentifier("fallingNotes")
    }

    private func y(forTime time: TimeInterval, height: CGFloat) -> CGFloat {
        height - CGFloat(session.zoom.fallPosition(forTime: time, playhead: session.playhead)) * height
    }

    private func drawBackdrop(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [PracticePalette.canvasTop, PracticePalette.background]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

    /// Key lane shading and octave lines so the player can visually trace notes down to the keys.
    private func drawGuides(in context: inout GraphicsContext, size: CGSize) {
        let keyboard = session.zoom.keyboard
        for note in keyboard.layout.range {
            guard let frame = keyboard.frame(for: note) else { continue }
            let x = CGFloat(frame.x) * size.width
            let w = CGFloat(frame.width) * size.width

            if MIDINote.isBlackKey(note) {
                let lane = Path(CGRect(x: x, y: 0, width: w, height: size.height))
                context.fill(lane, with: .color(.white.opacity(0.018)))
            } else if note % 12 == 0 {
                let line = Path(CGRect(x: x, y: 0, width: 1, height: size.height))
                context.fill(line, with: .color(.white.opacity(0.11)))
            } else if note % 12 == 5 {
                let line = Path(CGRect(x: x, y: 0, width: 0.5, height: size.height))
                context.fill(line, with: .color(.white.opacity(0.05)))
            }
        }
    }

    private func drawLoop(in context: inout GraphicsContext, size: CGSize) {
        guard let start = session.loopStart else { return }
        let bottom = y(forTime: start, height: size.height)
        let top = session.loopEnd.map { y(forTime: $0, height: size.height) } ?? bottom - 2
        let band = CGRect(x: 0, y: top, width: size.width, height: max(2, bottom - top))
        context.fill(Path(band), with: .color(PracticePalette.expected.opacity(0.12)))
    }

    private func drawNotes(in context: inout GraphicsContext, size: CGSize) {
        let keyboard = session.zoom.keyboard
        let windowEnd = session.playhead + session.zoom.lookaheadSeconds
        let selection = session.handSelection

        for step in session.song.steps {
            if step.timeSeconds > windowEnd { break }
            let isCurrent = session.state == .waiting && abs(step.timeSeconds - session.playhead) < 0.001

            for note in step.notes where note.endSeconds >= session.playhead {
                guard let frame = keyboard.frame(for: note.pitch) else { continue }

                let top = y(forTime: note.endSeconds, height: size.height)
                let bottom = y(forTime: note.startSeconds, height: size.height)
                let rect = CGRect(
                    x: CGFloat(frame.x) * size.width + 1.5,
                    y: top,
                    width: max(3, CGFloat(frame.width) * size.width - 3),
                    height: max(6, bottom - top)
                )

                let isLeft = note.hand == .left
                var baseColor = isLeft ? PracticePalette.leftHand : PracticePalette.rightHand
                var topColor = isLeft ? PracticePalette.leftHandTop : PracticePalette.rightHandTop
                let isActiveHand = selection.includes(note.hand)
                if !isActiveHand {
                    baseColor = baseColor.opacity(0.28)
                    topColor = topColor.opacity(0.28)
                }

                let isLatched = isCurrent && session.latchedNotes.contains(note.pitch)
                let radius = min(5, rect.width / 2.8)
                let shape = Path(roundedRect: rect, cornerRadius: radius)

                if isCurrent && isActiveHand {
                    let activeColor = isLatched ? PracticePalette.latched : PracticePalette.expected
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: activeColor.opacity(0.85), radius: 12))
                        layer.fill(
                            shape,
                            with: .linearGradient(
                                Gradient(colors: [topColor, baseColor]),
                                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                            )
                        )
                    }
                    context.stroke(shape, with: .color(activeColor.opacity(0.95)), lineWidth: 1.5)
                } else {
                    context.fill(
                        shape,
                        with: .linearGradient(
                            Gradient(colors: [topColor, baseColor]),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        )
                    )
                    context.stroke(shape, with: .color(.white.opacity(isActiveHand ? 0.22 : 0.08)), lineWidth: 0.75)
                }

                if differentiateWithoutColor && note.hand == .left {
                    context.stroke(shape, with: .color(.white), lineWidth: 1.5)
                }
            }
        }
    }

    private func drawHitLine(in context: inout GraphicsContext, size: CGSize) {
        let color = session.state == .waiting ? PracticePalette.expected : PracticePalette.rightHand.opacity(0.65)
        let glowRect = CGRect(x: 0, y: size.height - 6, width: size.width, height: 6)
        context.fill(
            Path(glowRect),
            with: .linearGradient(
                Gradient(colors: [.clear, color.opacity(0.35)]),
                startPoint: CGPoint(x: 0, y: size.height - 6),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        context.fill(Path(CGRect(x: 0, y: size.height - 2, width: size.width, height: 2)), with: .color(color))
    }
}
