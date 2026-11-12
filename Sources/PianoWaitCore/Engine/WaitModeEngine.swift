import Foundation

/// The practice state machine. It has no clock or audio of its own: call `tick` with elapsed time
/// and `ingest` with what the microphone heard, from one thread at a time.
public final class WaitModeEngine {
    public struct Configuration: Sendable, Equatable {
        /// How long a matched note stays latched while the rest of a chord is rolled in.
        public var rollWindow: TimeInterval = 0.6
        /// How long a freshly struck note remains armed before/across steps if not yet consumed.
        public var strikeMemorySeconds: TimeInterval? = nil
        /// A note struck this long before the playhead arrives still counts for the step.
        public var earlyGrace: TimeInterval = 0.25
        /// How far either side of a note's time it can be hit in Continuous mode.
        public var continuousWindow: TimeInterval = 0.25
        /// Time before the first note, which gives falling notes room to fall.
        public var leadIn: TimeInterval = 0
        /// How long the microphone is ignored for a pitch that the synthesizer just played.
        public var synthEchoSuppression: TimeInterval = 1.0
        /// When non-nil, a chord that has latched all but one note (with at least 75% or 2+ notes
        /// matched) completes after waiting this long since the last matched note was latched.
        public var partialChordGraceSeconds: TimeInterval? = nil
        /// How far ahead of the next step (in song seconds) `upcomingNotes` reports the next
        /// expected notes while playing between steps.
        public var highlightLeadTimeSeconds: TimeInterval = 1.5

        public init() {}
    }

    public static let speedRange: ClosedRange<Double> = 0.25...2.0
    public static let speedPresets: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5]

    public let song: MIDISong
    public var configuration: Configuration

    public private(set) var playhead: TimeInterval
    public private(set) var state: PlaybackState = .paused
    public private(set) var stats = PracticeStats()
    public private(set) var stepStatuses: [StepStatus]
    public private(set) var speed = 1.0
    public private(set) var mode: PlaybackMode
    public private(set) var handSelection: HandSelection = .both
    public private(set) var loopRange: ClosedRange<TimeInterval>?

    /// Plays the other hand through the synthesizer when practicing one hand.
    public var autoPlayAccompaniment = false
    /// Plays every note through the synthesizer in Continuous mode. The microphone can hear the
    /// speaker, so scoring is only meaningful with this on if the player wears headphones.
    public var playsReferenceAudio = false

    private var cursor = 0
    private var scoringCursor = 0
    private var clock: TimeInterval = 0
    private var pendingEvents: [PracticeEvent] = []
    private var previouslyHeard = Set<UInt8>()
    /// Notes that were already sounding at the moment the engine arrived at the current step
    /// and have not yet ceased sounding during this step.
    private var activeNotesAtStepStart = Set<UInt8>()
    /// When each note was last freshly struck, until a step uses that strike or the note stops.
    private var armedNotes: [UInt8: TimeInterval] = [:]
    private var latchedNotes: [UInt8: TimeInterval] = [:]
    private var continuousHits: [Int: Set<UInt8>] = [:]
    private var echoSuppressedUntil: [UInt8: TimeInterval] = [:]

    public init(song: MIDISong, mode: PlaybackMode = .waitForMe, configuration: Configuration = Configuration()) {
        self.song = song
        self.mode = mode
        self.configuration = configuration
        playhead = -configuration.leadIn
        stepStatuses = Array(repeating: .pending, count: song.steps.count)
    }

    // MARK: - Reading state

    public var isWaiting: Bool { state == .waiting }

    public var currentStepIndex: Int? { cursor < song.steps.count ? cursor : nil }

    /// The notes the player must play at the current step. Empty unless the engine is waiting.
    public var waitingNotes: Set<UInt8> {
        guard state == .waiting || (state == .paused && isAtCurrentStep) else { return [] }
        return expectedNotes(forStep: cursor)
    }

    /// The notes to highlight on the keyboard right now: `waitingNotes` when waiting, or the
    /// next step's expected notes for `handSelection` when playing within `highlightLeadTimeSeconds`.
    public var upcomingNotes: Set<UInt8> {
        if state == .waiting || (state == .paused && isAtCurrentStep) {
            return expectedNotes(forStep: cursor)
        }
        guard state == .playing, let idx = nextNonEmptyStepIndex(from: cursor) else { return [] }
        let dt = song.steps[idx].timeSeconds - playhead
        guard dt <= configuration.highlightLeadTimeSeconds else { return [] }
        return expectedNotes(forStep: idx)
    }

    public var latched: Set<UInt8> { Set(latchedNotes.keys) }

    /// The notes the microphone detector should be looking for right now.
    public var notesForDetector: Set<UInt8> {
        switch mode {
        case .waitForMe:
            guard let firstIdx = nextNonEmptyStepIndex(from: cursor) else { return [] }
            let notes = expectedNotes(forStep: firstIdx)
            let window = max(configuration.earlyGrace, configuration.strikeMemorySeconds ?? 0)
            guard let secondIdx = nextNonEmptyStepIndex(from: firstIdx + 1),
                  song.steps[secondIdx].timeSeconds - playhead <= window
            else { return notes }
            return notes.union(expectedNotes(forStep: secondIdx))
        case .continuous:
            var notes = Set<UInt8>()
            for index in scoringStepIndices() {
                notes.formUnion(expectedNotes(forStep: index))
            }
            return notes
        }
    }

    /// The share of steps finished in any way, from 0 to 1.
    public var progress: Double {
        guard !stepStatuses.isEmpty else { return 1 }
        return Double(stepStatuses.filter { $0 != .pending }.count) / Double(stepStatuses.count)
    }

    private var isAtCurrentStep: Bool {
        cursor < song.steps.count && abs(song.steps[cursor].timeSeconds - playhead) < 1e-9
    }

    private func expectedNotes(forStep index: Int) -> Set<UInt8> {
        song.steps[index].pitches(for: handSelection)
    }

    private func nextNonEmptyStepIndex(from startIndex: Int) -> Int? {
        guard startIndex < song.steps.count else { return nil }
        for idx in startIndex..<song.steps.count {
            if !expectedNotes(forStep: idx).isEmpty {
                return idx
            }
        }
        return nil
    }

    // MARK: - Transport

    public func play() {
        guard state == .paused else { return }
        state = .playing
        advance(by: 0)
    }

    public func pause() {
        guard state == .playing || state == .waiting else { return }
        state = .paused
    }

    /// Returns to the start of the song and clears all progress and statistics.
    public func restart() {
        playhead = -configuration.leadIn
        stepStatuses = Array(repeating: .pending, count: song.steps.count)
        stats = PracticeStats()
        cursor = 0
        scoringCursor = 0
        state = .paused
        clearMatchState()
        pendingEvents.removeAll()
    }

    /// Moves the playhead. Steps from `seconds` onward become pending again.
    public func seek(to seconds: TimeInterval) {
        let wasRunning = state == .playing || state == .waiting
        playhead = min(max(seconds, -configuration.leadIn), song.durationSeconds)
        cursor = firstStepIndex(atOrAfter: playhead)
        scoringCursor = firstStepIndex(atOrAfter: playhead - scoringWindow)
        for index in scoringCursor..<song.steps.count {
            stepStatuses[index] = .pending
        }
        clearMatchState()
        state = wasRunning ? .playing : .paused
        if wasRunning { advance(by: 0) }
    }

    /// Advances by real elapsed time, which speed scales, and returns what happened.
    @discardableResult
    public func tick(deltaTime: TimeInterval) -> [PracticeEvent] {
        if state == .playing || state == .waiting {
            clock += max(0, deltaTime)
            expireLatches()
            if state == .waiting {
                checkPartialChordGrace()
            }
            if state == .playing {
                advance(by: max(0, deltaTime) * speed)
            }
        }
        return drainEvents()
    }

    /// Returns events raised outside `tick`, such as by a step that `ingest` completed.
    public func drainEvents() -> [PracticeEvent] {
        defer { pendingEvents.removeAll() }
        return pendingEvents
    }

    // MARK: - Settings

    /// Sets the speed, clamped to `speedRange`. The playhead position is unaffected.
    public func setSpeed(_ newSpeed: Double) {
        speed = min(max(newSpeed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    public func setHandSelection(_ selection: HandSelection) {
        guard selection != handSelection else { return }
        handSelection = selection
        latchedNotes.removeAll()
        continuousHits.removeAll()
        if state == .waiting {
            state = .playing
            advance(by: 0)
        }
    }

    public func setMode(_ newMode: PlaybackMode) {
        guard newMode != mode else { return }
        mode = newMode
        latchedNotes.removeAll()
        continuousHits.removeAll()
        scoringCursor = cursor
        if state == .waiting { state = .playing }
        if state == .playing { advance(by: 0) }
    }

    /// Sets the A-B loop in seconds. Returns false, leaving the loop unchanged, if the range is
    /// empty. A playhead outside the new range moves to A.
    @discardableResult
    public func setLoop(start: TimeInterval, end: TimeInterval) -> Bool {
        let clampedStart = max(start, 0)
        let clampedEnd = min(end, song.durationSeconds)
        guard clampedStart < clampedEnd else { return false }
        loopRange = clampedStart...clampedEnd
        if playhead < clampedStart || playhead >= clampedEnd {
            seek(to: clampedStart)
        }
        return true
    }

    /// Sets the A-B loop from 1-based bar numbers, inclusive of both bars.
    @discardableResult
    public func setLoop(startBar: Int, endBar: Int) -> Bool {
        let bars = song.barStartSeconds
        guard startBar >= 1, endBar >= startBar, startBar <= bars.count else { return false }
        let end = endBar < bars.count ? bars[endBar] : song.durationSeconds
        return setLoop(start: bars[startBar - 1], end: end)
    }

    public func clearLoop() {
        loopRange = nil
    }

    // MARK: - Input

    /// Feeds one detector frame to the engine.
    public func ingest(_ frame: PitchDetectionFrameResult) {
        ingest(
            heard: frame.soundingNotes,
            onsets: frame.onsets,
            unambiguous: frame.activeNotes,
            matchedExpected: frame.matchedExpectedNotes
        )
    }

    /// Feeds the notes currently sounding. A note counts as newly played if it was not heard in
    /// the previous frame or it appears in `onsets`, so a note ringing on from an earlier step
    /// cannot satisfy a later one until it is struck again. Only `unambiguous` notes can count as
    /// wrong, because the others may just be overtones of what was played. Nil means all of them.
    public func ingest(
        heard: Set<UInt8>,
        onsets: Set<UInt8> = [],
        unambiguous: Set<UInt8>? = nil,
        matchedExpected: Set<UInt8> = []
    ) {
        guard state != .finished else { return }

        var fresh = heard.subtracting(previouslyHeard).union(onsets.intersection(heard))
        activeNotesAtStepStart.formIntersection(heard)
        activeNotesAtStepStart.subtract(fresh)
        if mode == .waitForMe, state == .waiting, cursor < song.steps.count {
            let expected = expectedNotes(forStep: cursor)
            if expected.count >= 2, !latchedNotes.isEmpty {
                let chordPresent = matchedExpected.intersection(expected)
                    .subtracting(latchedNotes.keys)
                    .subtracting(activeNotesAtStepStart)
                fresh.formUnion(chordPresent)
            }
        }
        fresh = fresh.filter { (echoSuppressedUntil[$0] ?? -.infinity) <= clock }
        previouslyHeard = heard

        for note in armedNotes.keys where !heard.contains(note) {
            if let memory = configuration.strikeMemorySeconds,
               let struckAt = armedNotes[note],
               clock - struckAt <= memory {
                continue
            }
            armedNotes[note] = nil
        }
        for note in fresh {
            armedNotes[note] = clock
        }

        guard state == .playing || state == .waiting else { return }
        expireLatches()
        match(fresh: fresh, wrongCandidates: unambiguous.map(fresh.intersection) ?? fresh)
    }

    /// Registers a note played on the on-screen keyboard.
    public func registerKeyPress(_ pitch: UInt8) {
        guard state == .playing || state == .waiting else { return }
        armedNotes[pitch] = clock
        // The key sounds through the speaker, and the microphone must not count it a second time.
        echoSuppressedUntil[pitch] = clock + configuration.synthEchoSuppression
        match(fresh: [pitch], wrongCandidates: [pitch])
    }

    /// Moves past the current or next step without playing it.
    public func skipStep() {
        guard mode == .waitForMe, cursor < song.steps.count, state != .finished else { return }
        let index = cursor
        let expected = expectedNotes(forStep: index)
        let hit = expected.intersection(latchedNotes.keys).count
        stats.notesHit += hit
        stats.notesMissed += expected.count - hit
        stats.stepsSkipped += 1
        stats.currentStreak = 0
        stepStatuses[index] = .skipped

        playhead = max(playhead, song.steps[index].timeSeconds)
        emitAudio(forStep: index)
        finishCurrentStep()
    }

    // MARK: - Playhead

    private func advance(by songTime: TimeInterval) {
        var remaining = songTime
        while state == .playing {
            var target = song.durationSeconds
            if let loop = loopRange, playhead < loop.upperBound { target = min(target, loop.upperBound) }
            if cursor < song.steps.count { target = min(target, song.steps[cursor].timeSeconds) }

            guard playhead + remaining >= target else {
                playhead += remaining
                remaining = 0
                break
            }
            remaining -= max(0, target - playhead)
            playhead = max(playhead, target)

            if let loop = loopRange, playhead >= loop.upperBound {
                jumpToLoopStart(loop)
            } else if cursor < song.steps.count, song.steps[cursor].timeSeconds <= playhead {
                arrive(atStep: cursor)
            } else {
                finish()
            }
        }
        if mode == .continuous { finalizePassedContinuousSteps() }
    }

    private func arrive(atStep index: Int) {
        let expected = expectedNotes(forStep: index)
        if expected.isEmpty {
            stepStatuses[index] = .autoPassed
            emitAudio(forStep: index)
            cursor += 1
            if mode == .continuous { finalizePassedContinuousSteps() }
            return
        }

        switch mode {
        case .continuous:
            emitAudio(forStep: index)
            cursor += 1
            finalizePassedContinuousSteps()
            consumeArmedNotes()
        case .waitForMe:
            state = .waiting
            latchedNotes.removeAll()
            activeNotesAtStepStart = previouslyHeard
            consumeArmedNotes()
        }
    }

    /// At arrival, a recent strike counts as playing slightly early. Older ones are stale.
    private func consumeArmedNotes() {
        let window = max(configuration.earlyGrace, configuration.strikeMemorySeconds ?? 0)
        let recent = armedNotes.filter { clock - $0.value <= window }
        switch mode {
        case .waitForMe:
            armedNotes = armedNotes.filter { !expectedNotes(forStep: cursor).contains($0.key) }
            let matchedEarly = Set(recent.keys).intersection(expectedNotes(forStep: cursor))
            activeNotesAtStepStart.subtract(matchedEarly)
            match(armed: matchedEarly)
        case .continuous:
            matchContinuous(fresh: Set(recent.keys), wrongCandidates: [])
        }
    }

    private func match(fresh: Set<UInt8>, wrongCandidates: Set<UInt8>) {
        switch mode {
        case .waitForMe:
            guard state == .waiting, cursor < song.steps.count else { return }
            let expected = expectedNotes(forStep: cursor)
            let wrong = wrongCandidates.subtracting(expected)
            if !wrong.isEmpty {
                stats.wrongNotes += wrong.count
                stats.currentStreak = 0
            }
            match(armed: fresh.intersection(expected))
        case .continuous:
            matchContinuous(fresh: fresh, wrongCandidates: wrongCandidates)
        }
    }

    private func match(armed notes: Set<UInt8>) {
        guard cursor < song.steps.count else { return }
        for note in notes {
            latchedNotes[note] = clock
            armedNotes[note] = nil
        }

        let expected = expectedNotes(forStep: cursor)
        guard !expected.isEmpty, expected.isSubset(of: latchedNotes.keys) else { return }

        let index = cursor
        stats.notesHit += expected.count
        stats.stepsCompleted += 1
        stats.currentStreak += 1
        stats.bestStreak = max(stats.bestStreak, stats.currentStreak)
        stepStatuses[index] = .completed
        pendingEvents.append(.stepCompleted(index: index))
        emitAudio(forStep: index)
        finishCurrentStep()
    }

    private func checkPartialChordGrace() {
        guard mode == .waitForMe,
              state == .waiting,
              let grace = configuration.partialChordGraceSeconds,
              cursor < song.steps.count
        else { return }
        let expected = expectedNotes(forStep: cursor)
        guard expected.count >= 2 else { return }
        let matchedCount = expected.intersection(latchedNotes.keys).count
        let missingCount = expected.count - matchedCount
        guard matchedCount >= 1, missingCount == 1 else { return }
        guard let firstLatch = latchedNotes.values.min(), clock - firstLatch >= grace else { return }

        let index = cursor
        stats.notesHit += matchedCount
        stats.stepsCompleted += 1
        stats.currentStreak += 1
        stats.bestStreak = max(stats.bestStreak, stats.currentStreak)
        stepStatuses[index] = .completed
        pendingEvents.append(.stepCompleted(index: index))
        emitAudio(forStep: index)
        finishCurrentStep()
    }

    private func finishCurrentStep() {
        latchedNotes.removeAll()
        cursor += 1
        scoringCursor = cursor
        if state == .waiting { state = .playing }
        if state == .playing { advance(by: 0) }
    }

    /// Unlatches notes that have outlived the roll window, unless they are still sounding.
    private func expireLatches() {
        guard mode == .waitForMe else { return }
        for (note, time) in latchedNotes where clock - time > configuration.rollWindow {
            if previouslyHeard.contains(note) {
                latchedNotes[note] = clock
            } else {
                latchedNotes[note] = nil
            }
        }
    }

    private func jumpToLoopStart(_ loop: ClosedRange<TimeInterval>) {
        if mode == .continuous { finalizePassedContinuousSteps(through: loop.upperBound) }
        for index in song.steps.indices where loop.contains(song.steps[index].timeSeconds)
            && song.steps[index].timeSeconds < loop.upperBound {
            stepStatuses[index] = .pending
        }
        playhead = loop.lowerBound
        cursor = firstStepIndex(atOrAfter: playhead)
        scoringCursor = cursor
        latchedNotes.removeAll()
        armedNotes.removeAll()
        continuousHits.removeAll()
        pendingEvents.append(.looped)
    }

    private func finish() {
        if mode == .continuous { finalizePassedContinuousSteps(through: .infinity) }
        playhead = song.durationSeconds
        state = .finished
        pendingEvents.append(.finished)
    }

    private func emitAudio(forStep index: Int) {
        let plays: (SongNote) -> Bool
        switch mode {
        case .waitForMe:
            guard autoPlayAccompaniment, handSelection != .both else { return }
            plays = { [handSelection] in !handSelection.includes($0.hand) }
        case .continuous:
            if playsReferenceAudio {
                plays = { _ in true }
            } else if autoPlayAccompaniment, handSelection != .both {
                plays = { [handSelection] in !handSelection.includes($0.hand) }
            } else {
                return
            }
        }

        for note in song.steps[index].notes where plays(note) {
            pendingEvents.append(.playNote(
                pitch: note.pitch,
                velocity: note.velocity,
                duration: note.durationSeconds / speed
            ))
            if mode == .waitForMe || !handSelection.includes(note.hand) {
                // The microphone will hear this note, and the player did not play it.
                echoSuppressedUntil[note.pitch] = clock + configuration.synthEchoSuppression
            }
        }
    }

    private func clearMatchState() {
        latchedNotes.removeAll()
        armedNotes.removeAll()
        continuousHits.removeAll()
        activeNotesAtStepStart.removeAll()
    }

    private func firstStepIndex(atOrAfter seconds: TimeInterval) -> Int {
        song.steps.firstIndex { $0.timeSeconds >= seconds } ?? song.steps.count
    }

    // MARK: - Continuous scoring

    private var scoringWindow: TimeInterval {
        configuration.continuousWindow * speed
    }

    private func scoringStepIndices() -> [Int] {
        var indices: [Int] = []
        var index = scoringCursor
        while index < song.steps.count, song.steps[index].timeSeconds <= playhead + scoringWindow {
            if stepStatuses[index] == .pending, abs(song.steps[index].timeSeconds - playhead) <= scoringWindow {
                indices.append(index)
            }
            index += 1
        }
        return indices
    }

    private func matchContinuous(fresh: Set<UInt8>, wrongCandidates: Set<UInt8>) {
        var unmatched = fresh
        for index in scoringStepIndices() {
            let expected = expectedNotes(forStep: index)
            guard !expected.isEmpty else { continue }

            var hits = continuousHits[index] ?? []
            let newHits = unmatched.intersection(expected).subtracting(hits)
            hits.formUnion(newHits)
            unmatched.subtract(newHits)
            for note in newHits { armedNotes[note] = nil }
            continuousHits[index] = hits

            if hits == expected { completeContinuous(index: index, hits: hits) }
        }
        let wrong = unmatched.intersection(wrongCandidates)
        if !wrong.isEmpty {
            stats.wrongNotes += wrong.count
            stats.currentStreak = 0
        }
    }

    private func completeContinuous(index: Int, hits: Set<UInt8>) {
        stats.notesHit += hits.count
        stats.stepsCompleted += 1
        stats.currentStreak += 1
        stats.bestStreak = max(stats.bestStreak, stats.currentStreak)
        stepStatuses[index] = .completed
        continuousHits[index] = nil
        pendingEvents.append(.stepCompleted(index: index))
    }

    private func finalizePassedContinuousSteps(through limit: TimeInterval? = nil) {
        let deadline = limit ?? (playhead - scoringWindow)
        while scoringCursor < song.steps.count, song.steps[scoringCursor].timeSeconds < deadline {
            let index = scoringCursor
            if stepStatuses[index] == .pending {
                let expected = expectedNotes(forStep: index)
                if expected.isEmpty {
                    stepStatuses[index] = .autoPassed
                } else {
                    let hits = continuousHits[index] ?? []
                    stats.notesHit += hits.count
                    stats.notesMissed += expected.count - hits.count
                    stats.currentStreak = 0
                    stepStatuses[index] = .missed
                    continuousHits[index] = nil
                }
            }
            scoringCursor += 1
        }
    }
}
