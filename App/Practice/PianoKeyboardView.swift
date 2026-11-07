import PianoWaitCore
import SwiftUI

/// A playable keyboard showing expected keys, latched chord notes, and what the microphone hears.
struct PianoKeyboardView: View {
    let session: PracticeSession
    @State private var touchedKey: UInt8?
    @State private var viewSize = CGSize.zero
    @State private var isPinching = false
    @State private var isPanning = false
    /// Where the current touch began, and the touch that started a two-finger gesture. That touch
    /// must not play a note, even once the other finger has lifted.
    @State private var currentTouchStart: CGPoint?
    @State private var ignoredTouchStart: CGPoint?

    var body: some View {
        Canvas { context, size in
            let notes = session.zoom.keyboard.layout.range

            for note in notes where !MIDINote.isBlackKey(note) {
                draw(note: note, in: &context, size: size)
            }
            for note in notes where MIDINote.isBlackKey(note) {
                draw(note: note, in: &context, size: size)
            }
        }
        .clipped()
        .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleTouch(value)
                }
                .onEnded { _ in
                    releaseTouchedKey()
                    currentTouchStart = nil
                }
        )
        .pinchToZoomKeyboard(session: session) { isActive in
            isPinching = isActive
            if isActive { ignoreCurrentTouch() }
        }
        .gesture(
            TwoFingerPanGesture { isActive in
                isPanning = isActive
                if isActive { ignoreCurrentTouch() }
            } onPan: { step in
                guard viewSize.width > 0 else { return }
                session.zoom.keyboard = session.zoom.keyboard.panned(by: -step / viewSize.width)
            }
        )
        .accessibilityElement()
        .accessibilityLabel("Piano keyboard")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("pianoKeyboard")
    }

    private func handleTouch(_ value: DragGesture.Value) {
        currentTouchStart = value.startLocation
        if isPinching || isPanning { ignoredTouchStart = value.startLocation }
        guard value.startLocation != ignoredTouchStart else { return }

        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let note = session.zoom.keyboard.note(
            atX: value.location.x / viewSize.width,
            y: value.location.y / viewSize.height
        )
        guard note != touchedKey else { return }
        if let touchedKey { session.keyReleased(touchedKey) }
        touchedKey = note
        if let note { session.keyPressed(note) }
    }

    private func ignoreCurrentTouch() {
        ignoredTouchStart = currentTouchStart
        releaseTouchedKey()
    }

    private func releaseTouchedKey() {
        if let touchedKey { session.keyReleased(touchedKey) }
        touchedKey = nil
    }

    private func draw(note: UInt8, in context: inout GraphicsContext, size: CGSize) {
        guard let frame = session.zoom.keyboard.frame(for: note) else { return }

        let isBlack = MIDINote.isBlackKey(note)
        let height = isBlack ? size.height * PianoKeyboardLayout.blackKeyHeightRatio : size.height
        let rect = CGRect(
            x: CGFloat(frame.x) * size.width,
            y: 0,
            width: CGFloat(frame.width) * size.width,
            height: height
        ).insetBy(dx: isBlack ? 0 : 0.6, dy: 0)
        let cornerRadius = min(isBlack ? 4.5 : 5.5, rect.width / 3.5)
        let shape = Path(roundedRect: rect, cornerRadius: cornerRadius)

        let isLatched = session.latchedNotes.contains(note)
        let isWaiting = session.waitingNotes.contains(note)
        let isPressed = session.pressedKeys.contains(note)

        if isLatched || isWaiting {
            let color = isLatched ? PracticePalette.latched : PracticePalette.expected
            context.fill(
                shape,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.95), color]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
        } else if isPressed {
            context.fill(shape, with: .color(Color(white: isBlack ? 0.25 : 0.78)))
        } else if isBlack {
            context.fill(
                shape,
                with: .linearGradient(
                    Gradient(colors: [Color(white: 0.18), Color(white: 0.07)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
            let highlight = rect.insetBy(dx: 1.5, dy: 1.5)
            if highlight.width > 2 && highlight.height > 4 {
                context.stroke(
                    Path(roundedRect: highlight, cornerRadius: max(1, cornerRadius - 1)),
                    with: .color(.white.opacity(0.12)),
                    lineWidth: 0.75
                )
            }
        } else {
            context.fill(
                shape,
                with: .linearGradient(
                    Gradient(colors: [Color(white: 0.99), Color(white: 0.91)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
            context.stroke(shape, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
        }

        if note % 12 == 0 && !isBlack && rect.width >= 14 {
            context.draw(
                Text(MIDINote.name(note))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.5)),
                at: CGPoint(x: rect.midX, y: rect.maxY - 11)
            )
        }

        // A dot shows the microphone hearing a key, on top of whatever state that key is in.
        if session.heardNotes.contains(note) {
            let diameter = min(rect.width * 0.55, 11)
            let dot = CGRect(
                x: rect.midX - diameter / 2,
                y: rect.maxY - diameter - (rect.width >= 14 && note % 12 == 0 ? 22 : 7),
                width: diameter,
                height: diameter
            )
            context.fill(Path(ellipseIn: dot), with: .color(PracticePalette.heard))
        }
    }

    private var accessibilitySummary: String {
        let expected = session.waitingNotes.subtracting(session.latchedNotes).sorted().map(MIDINote.name)
        return expected.isEmpty ? "No notes expected" : "Play \(expected.joined(separator: ", "))"
    }
}
