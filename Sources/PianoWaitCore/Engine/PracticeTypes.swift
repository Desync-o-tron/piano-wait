import Foundation

public enum HandSelection: String, Sendable, Hashable, CaseIterable, Identifiable {
    case both
    case right
    case left

    public var id: String { rawValue }

    public func includes(_ hand: Hand) -> Bool {
        switch self {
        case .both: true
        case .right: hand == .right
        case .left: hand == .left
        }
    }
}

public enum PlaybackMode: String, Sendable, Hashable, CaseIterable {
    /// The playhead stops at every step until the player has played it.
    case waitForMe
    /// The playhead never stops, and notes are scored as they go by.
    case continuous
}

public enum PlaybackState: Sendable, Hashable {
    case paused
    case playing
    case waiting
    case finished
}

public enum StepStatus: Sendable, Hashable {
    case pending
    case completed
    case skipped
    case missed
    /// The step has no notes for the selected hand.
    case autoPassed
}

public enum PracticeEvent: Sendable, Hashable {
    /// The app should sound this note through the synthesizer.
    case playNote(pitch: UInt8, velocity: UInt8, duration: TimeInterval)
    case stepCompleted(index: Int)
    case looped
    case finished
}

public struct PracticeStats: Sendable, Hashable {
    public var notesHit = 0
    public var notesMissed = 0
    public var wrongNotes = 0
    public var stepsCompleted = 0
    public var stepsSkipped = 0
    public var currentStreak = 0
    public var bestStreak = 0

    public init() {}

    /// The share of attempts that were correct, or 1 before any attempts.
    public var accuracy: Double {
        let attempts = notesHit + notesMissed + wrongNotes
        return attempts == 0 ? 1 : Double(notesHit) / Double(attempts)
    }
}
