import Foundation

/// How much of a song the practice screen shows: which keys, and how many seconds ahead.
public struct PracticeZoom: Sendable, Equatable {
    public static let lookaheadRange = 2.0...8.0
    public static let defaultLookahead = 4.0
    private static let zoomStep = 1.25
    private static let panStep = 0.25

    public var keyboard: PianoKeyboardViewport
    /// Seconds of music between the top of the falling notes and the keyboard.
    public var lookaheadSeconds = PracticeZoom.defaultLookahead {
        didSet {
            lookaheadSeconds = min(max(lookaheadSeconds, Self.lookaheadRange.lowerBound), Self.lookaheadRange.upperBound)
        }
    }

    private let songFit: PianoKeyboardViewport

    /// Starts on the part of the 88 keys that the song uses.
    public init(song: MIDISong) {
        songFit = PianoKeyboardViewport(fitting: PianoKeyboardLayout.autoZoomed(for: song).range)
        keyboard = songFit
    }

    public var isFittedToSong: Bool { keyboard.isApproximatelyEqual(to: songFit) }

    public var showsAllKeys: Bool { !keyboard.canZoomOut }

    public mutating func zoomIn() {
        keyboard = keyboard.zoomed(by: Self.zoomStep)
    }

    public mutating func zoomOut() {
        keyboard = keyboard.zoomed(by: 1 / Self.zoomStep)
    }

    public mutating func panLeft() {
        keyboard = keyboard.panned(by: -Self.panStep)
    }

    public mutating func panRight() {
        keyboard = keyboard.panned(by: Self.panStep)
    }

    public mutating func fitSong() {
        keyboard = songFit
    }

    public mutating func showAllKeys() {
        keyboard = PianoKeyboardViewport(layout: keyboard.layout)
    }

    /// A time's height above the keyboard, as a fraction of the falling notes view: 0 at the
    /// keyboard, and 1 at the top.
    public func fallPosition(forTime time: TimeInterval, playhead: TimeInterval) -> Double {
        (time - playhead) / lookaheadSeconds
    }
}
