import Foundation

/// The part of a keyboard on screen, shared by the keys and the falling notes. `start` and `width`
/// are in the layout's units, and positions going in and out are in units where the view is 1 wide.
public struct PianoKeyboardViewport: Sendable, Equatable {
    /// Zooming stops at one octave, where the keys are already wider than a fingertip.
    public static let minimumVisibleWhiteKeys = 7.0
    private static let tolerance = 1e-9

    public let layout: PianoKeyboardLayout
    public let start: Double
    public let width: Double

    /// A view of the layout, moved and sized as needed to stay on the keyboard.
    public init(layout: PianoKeyboardLayout = PianoKeyboardLayout(), start: Double = 0, width: Double = 1) {
        let minimumWidth = min(1, Self.minimumVisibleWhiteKeys * layout.whiteKeyWidth)
        let clampedWidth = min(max(width, minimumWidth), 1)
        self.layout = layout
        self.width = clampedWidth
        self.start = min(max(start, 0), 1 - clampedWidth)
    }

    /// A view that starts and ends on the white keys around `range`.
    public init(layout: PianoKeyboardLayout = PianoKeyboardLayout(), fitting range: ClosedRange<UInt8>) {
        let fitted = PianoKeyboardLayout(range: range).range
        guard let low = layout.frame(for: fitted.lowerBound), let high = layout.frame(for: fitted.upperBound) else {
            self.init(layout: layout)
            return
        }
        self.init(layout: layout, start: low.x, width: high.x + high.width - low.x)
    }

    public var canZoomIn: Bool {
        width - Self.tolerance > min(1, Self.minimumVisibleWhiteKeys * layout.whiteKeyWidth)
    }

    public var canZoomOut: Bool { width + Self.tolerance < 1 }

    public var canPanLeft: Bool { start > Self.tolerance }

    public var canPanRight: Bool { start + width + Self.tolerance < 1 }

    /// The keys whose centers are on screen.
    public var visibleNotes: ClosedRange<UInt8> {
        let notes = layout.range.filter { note in
            guard let frame = layout.frame(for: note) else { return false }
            let center = frame.x + frame.width / 2
            return center >= start && center <= start + width
        }
        guard let first = notes.first, let last = notes.last else { return layout.range }
        return first...last
    }

    /// Scales by `factor`, where above 1 zooms in, holding still the point at `anchor` in the view.
    public func zoomed(by factor: Double, anchor: Double = 0.5) -> PianoKeyboardViewport {
        guard factor > 0, factor.isFinite else { return self }
        let newWidth = width / factor
        return PianoKeyboardViewport(
            layout: layout,
            start: start + anchor * width - anchor * newWidth,
            width: newWidth
        )
    }

    /// Moves by a fraction of the view. Positive amounts move toward higher notes.
    public func panned(by amount: Double) -> PianoKeyboardViewport {
        PianoKeyboardViewport(layout: layout, start: start + amount * width, width: width)
    }

    public func isApproximatelyEqual(to other: PianoKeyboardViewport) -> Bool {
        abs(start - other.start) < Self.tolerance && abs(width - other.width) < Self.tolerance
    }

    /// The key's extent in the view, or nil if none of it is on screen.
    public func frame(for note: UInt8) -> PianoKeyboardLayout.KeyFrame? {
        guard let frame = layout.frame(for: note) else { return nil }
        let x = (frame.x - start) / width
        let keyWidth = frame.width / width
        guard x + keyWidth > 0, x < 1 else { return nil }
        return PianoKeyboardLayout.KeyFrame(x: x, width: keyWidth)
    }

    /// The key at a position in the view, with `y` as in `PianoKeyboardLayout.note(atX:y:)`.
    public func note(atX x: Double, y: Double) -> UInt8? {
        guard x >= 0, x < 1 else { return nil }
        return layout.note(atX: start + x * width, y: y)
    }
}
