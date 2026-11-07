import Foundation

public enum Hand: String, Sendable, Hashable, Codable, CaseIterable {
    case left
    case right
}

public struct SongNote: Sendable, Hashable {
    public let pitch: UInt8
    public let velocity: UInt8
    public let startTick: Int
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let track: Int
    public let channel: UInt8
    public let hand: Hand

    public var durationSeconds: TimeInterval { endSeconds - startSeconds }
}

/// A group of notes that must be played together before Wait Mode moves on.
public struct ChordStep: Sendable, Hashable, Identifiable {
    public let index: Int
    public let timeSeconds: TimeInterval
    public let notes: [SongNote]

    public var id: Int { index }

    public var pitches: Set<UInt8> { Set(notes.map(\.pitch)) }

    public func pitches(for selection: HandSelection) -> Set<UInt8> {
        Set(notes.filter { selection.includes($0.hand) }.map(\.pitch))
    }
}

public struct TempoEvent: Sendable, Hashable {
    public let tick: Int
    public let microsecondsPerQuarter: Int
    public let seconds: TimeInterval

    public var beatsPerMinute: Double { 60_000_000 / Double(microsecondsPerQuarter) }
}

public struct TimeSignatureEvent: Sendable, Hashable {
    public let tick: Int
    public let numerator: Int
    public let denominator: Int
    public let seconds: TimeInterval
}

public struct MIDISong: Sendable, Hashable {
    public let title: String
    public let format: Int
    public let trackNames: [String]
    public let tempoEvents: [TempoEvent]
    public let timeSignatures: [TimeSignatureEvent]
    public let notes: [SongNote]
    public let steps: [ChordStep]
    public let durationSeconds: TimeInterval
    /// Song time of each bar line, starting at bar 1. Empty for SMPTE-timed files.
    public let barStartSeconds: [TimeInterval]
    /// Notes dropped because a piano cannot play them: percussion channel or outside A0...C8.
    public let droppedNoteCount: Int

    public var noteCount: Int { notes.count }

    public var pitchRange: ClosedRange<UInt8>? {
        guard let low = notes.map(\.pitch).min(), let high = notes.map(\.pitch).max() else { return nil }
        return low...high
    }
}
