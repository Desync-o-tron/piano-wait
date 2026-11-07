import Foundation

/// Maps notes to horizontal positions on a keyboard, in units where the keyboard is 1 wide.
public struct PianoKeyboardLayout: Sendable, Equatable {
    public struct KeyFrame: Sendable, Equatable {
        public let x: Double
        public let width: Double
    }

    public static let blackKeyWidthRatio = 0.62
    public static let blackKeyHeightRatio = 0.62
    private static let minimumAutoZoomSemitones = 24

    public let range: ClosedRange<UInt8>

    private let whiteKeys: [UInt8]
    private let whiteIndex: [UInt8: Int]

    public init(range: ClosedRange<UInt8> = MIDINote.pianoRange) {
        // The keyboard always starts and ends on white keys, so black keys have a neighbor.
        var low = range.lowerBound
        var high = range.upperBound
        if MIDINote.isBlackKey(low), low > 0 { low -= 1 }
        if MIDINote.isBlackKey(high), high < 127 { high += 1 }

        self.range = low...high
        whiteKeys = (low...high).filter { !MIDINote.isBlackKey($0) }
        whiteIndex = Dictionary(uniqueKeysWithValues: whiteKeys.enumerated().map { ($0.element, $0.offset) })
    }

    /// A keyboard fitted to the notes of a song, with some margin and at least two octaves.
    public static func autoZoomed(for song: MIDISong) -> PianoKeyboardLayout {
        guard let pitches = song.pitchRange else { return PianoKeyboardLayout() }
        var low = Int(pitches.lowerBound) - 2
        var high = Int(pitches.upperBound) + 2
        let shortfall = minimumAutoZoomSemitones - (high - low)
        if shortfall > 0 {
            low -= shortfall / 2
            high += shortfall - shortfall / 2
        }
        let piano = MIDINote.pianoRange
        return PianoKeyboardLayout(
            range: UInt8(max(low, Int(piano.lowerBound)))...UInt8(min(high, Int(piano.upperBound)))
        )
    }

    public var whiteKeyCount: Int { whiteKeys.count }

    public var whiteKeyWidth: Double { 1 / Double(whiteKeys.count) }

    /// The key's horizontal extent, or nil if the note is not on this keyboard.
    public func frame(for note: UInt8) -> KeyFrame? {
        guard range.contains(note) else { return nil }
        if let index = whiteIndex[note] {
            return KeyFrame(x: Double(index) * whiteKeyWidth, width: whiteKeyWidth)
        }
        guard let lowerWhite = whiteIndex[note - 1] else { return nil }
        let width = whiteKeyWidth * Self.blackKeyWidthRatio
        return KeyFrame(x: Double(lowerWhite + 1) * whiteKeyWidth - width / 2, width: width)
    }

    /// The key at a position. `y` runs from 0 at the back of the keys to 1 at the front, and black
    /// keys, which sit on top, only exist in the back part.
    public func note(atX x: Double, y: Double) -> UInt8? {
        guard x >= 0, x < 1 else { return nil }
        if y < Self.blackKeyHeightRatio {
            for note in range where MIDINote.isBlackKey(note) {
                if let frame = frame(for: note), x >= frame.x, x < frame.x + frame.width {
                    return note
                }
            }
        }
        return whiteKeys[min(Int(x / whiteKeyWidth), whiteKeys.count - 1)]
    }
}
