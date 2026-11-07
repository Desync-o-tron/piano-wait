import Foundation
import XCTest
@testable import PianoWaitCore

/// Plays whole songs through the real pipeline: MIDI bytes into the parser, a simulated player
/// striking a simulated piano, synthesized audio through the detector, and into the engine.
final class EndToEndPracticeSimulationTests: XCTestCase {
    private static let sampleRate = 44_100.0
    private static let hop = TestPianoSignalGenerator.hopSize

    /// A player who reacts after a delay, sometimes plays a wrong note first, and sometimes rolls
    /// a chord. They only strike notes the song asks for, so a step that completes without all of
    /// its notes having been struck is a false advance.
    private final class SimulatedPlayer {
        private enum Action {
            case strike(UInt8)
            case release(UInt8)
            case releaseAll
        }

        private let room: SimulatedPianoRoom
        private var random: SeededGenerator
        private let wrongNoteEvery: Int
        private let rollEvery: Int
        private var schedule: [(time: TimeInterval, action: Action)] = []
        private var plannedStep: Int?
        private var attemptDeadline: TimeInterval = .infinity

        private(set) var struckByStep: [Int: Set<UInt8>] = [:]
        private(set) var wrongNotesPlayed = 0
        private(set) var retries = 0

        init(room: SimulatedPianoRoom, seed: UInt64, wrongNoteEvery: Int, rollEvery: Int) {
            self.room = room
            random = SeededGenerator(seed: seed)
            self.wrongNoteEvery = wrongNoteEvery
            self.rollEvery = rollEvery
        }

        func update(now: TimeInterval, engine: WaitModeEngine) {
            if engine.isWaiting, let step = engine.currentStepIndex {
                if plannedStep != step {
                    plannedStep = step
                    plan(step: step, notes: engine.waitingNotes, now: now, isRetry: false)
                } else if now > attemptDeadline {
                    // The player notices that nothing happened and plays it again.
                    retries += 1
                    plan(step: step, notes: engine.waitingNotes, now: now, isRetry: true)
                }
            }

            while let next = schedule.first, next.time <= now {
                schedule.removeFirst()
                switch next.action {
                case .strike(let note):
                    room.strike(note)
                    if let step = plannedStep { struckByStep[step, default: []].insert(note) }
                case .release(let note):
                    room.release(note)
                case .releaseAll:
                    room.releaseAll()
                }
            }
        }

        private func plan(step: Int, notes: Set<UInt8>, now: TimeInterval, isRetry: Bool) {
            schedule.removeAll()
            var time = now + Double.random(in: 0.12...0.4, using: &random)
            // Lifting the hand drops the dampers before the next notes are struck.
            schedule.append((time, .releaseAll))
            time += 0.12

            if !isRetry, wrongNoteEvery > 0, step % wrongNoteEvery == wrongNoteEvery - 1,
               let top = notes.max() {
                let wrong = wrongNote(near: top, avoiding: notes)
                wrongNotesPlayed += 1
                schedule.append((time, .strike(wrong)))
                time += Double.random(in: 0.35...0.55, using: &random)
                schedule.append((time, .release(wrong)))
                time += 0.12
            }

            let isRolled = rollEvery > 0 && notes.count > 1 && step % rollEvery == 0
            for note in notes.sorted() {
                schedule.append((time, .strike(note)))
                if isRolled { time += Double.random(in: 0.08...0.16, using: &random) }
            }
            attemptDeadline = time + 1.5
        }

        /// A semitone away is the classic slip, and it shares no partials with the target.
        private func wrongNote(near top: UInt8, avoiding notes: Set<UInt8>) -> UInt8 {
            var candidate = top + 1
            while notes.contains(candidate) { candidate += 1 }
            return candidate
        }
    }

    private struct Outcome {
        let engine: WaitModeEngine
        let player: SimulatedPlayer
        let falseAdvances: [String]
    }

    /// Runs the whole pipeline until the song finishes or `timeLimit` seconds of audio have passed.
    private func perform(
        _ song: MIDISong,
        hands: HandSelection = .both,
        speed: Double = 1,
        seed: UInt64 = 11,
        wrongNoteEvery: Int = 6,
        rollEvery: Int = 2,
        timeLimit: TimeInterval = 900
    ) -> Outcome {
        let room = SimulatedPianoRoom(sampleRate: Self.sampleRate, seed: seed)
        let player = SimulatedPlayer(room: room, seed: seed, wrongNoteEvery: wrongNoteEvery, rollEvery: rollEvery)
        let detector = AcousticPitchDetector()
        var assembler = AudioFrameAssembler()
        let engine = WaitModeEngine(song: song)
        engine.setHandSelection(hands)
        engine.setSpeed(speed)
        engine.play()

        let hopSeconds = Double(Self.hop) / Self.sampleRate
        var now: TimeInterval = 0
        var falseAdvances: [String] = []

        func audit(_ events: [PracticeEvent]) {
            for case .stepCompleted(let index) in events {
                let expected = song.steps[index].pitches(for: hands)
                let struck = player.struckByStep[index] ?? []
                if !expected.isSubset(of: struck) {
                    falseAdvances.append(
                        "step \(index): needed \(expected.sorted().map(MIDINote.name)), player struck \(struck.sorted().map(MIDINote.name))"
                    )
                }
            }
        }

        while engine.state != .finished, now < timeLimit {
            audit(engine.tick(deltaTime: hopSeconds))
            player.update(now: now, engine: engine)

            for frame in assembler.append(room.nextSamples(count: Self.hop)) {
                let result = detector.processAudioBuffer(
                    samples: frame,
                    sampleRate: Self.sampleRate,
                    expectedNotes: engine.notesForDetector
                )
                engine.ingest(result)
                audit(engine.drainEvents())
            }
            now += hopSeconds
        }
        return Outcome(engine: engine, player: player, falseAdvances: falseAdvances)
    }

    private func assertComplete(_ outcome: Outcome, label: String, line: UInt = #line) {
        let engine = outcome.engine
        let unfinished = engine.stepStatuses.enumerated().filter { $0.element == .pending }.map(\.offset)
        XCTAssertEqual(engine.state, .finished, "\(label): stuck at step \(engine.currentStepIndex ?? -1), waiting for \(engine.waitingNotes.sorted().map(MIDINote.name)), retries \(outcome.player.retries)", line: line)
        XCTAssertEqual(engine.progress, 1, label, line: line)
        XCTAssertEqual(engine.playhead, engine.song.durationSeconds, accuracy: 1e-6, label, line: line)
        XCTAssertTrue(unfinished.isEmpty, "\(label): unfinished steps \(unfinished)", line: line)
        XCTAssertEqual(engine.stats.stepsSkipped, 0, label, line: line)
        XCTAssertTrue(outcome.falseAdvances.isEmpty, "\(label) false advances: \(outcome.falseAdvances)", line: line)
    }

    // MARK: - Whole songs

    func testOdeToJoyBothHandsToCompletion() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.odeToJoy.midiData)
        XCTAssertGreaterThan(song.barStartSeconds.count, 8, "This must be a multi-bar song.")

        let outcome = perform(song)

        assertComplete(outcome, label: "Ode to Joy")
        XCTAssertEqual(outcome.engine.stats.stepsCompleted, song.steps.count)
        XCTAssertEqual(outcome.engine.stats.notesHit, song.steps.reduce(0) { $0 + $1.pitches.count })
        XCTAssertGreaterThan(outcome.player.wrongNotesPlayed, 0, "The simulation must include wrong notes.")
        XCTAssertGreaterThan(outcome.engine.stats.wrongNotes, 0, "Wrong notes must be noticed.")
    }

    func testMinuetInGBothHandsToCompletion() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.minuetInG.midiData)
        let outcome = perform(song)
        assertComplete(outcome, label: "Minuet in G")
        XCTAssertEqual(outcome.engine.stats.stepsCompleted, song.steps.count)
    }

    func testFurEliseBothHandsToCompletion() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.furElise.midiData)
        let outcome = perform(song)
        assertComplete(outcome, label: "Für Elise")
        XCTAssertEqual(outcome.engine.stats.stepsCompleted, song.steps.count)
    }

    func testChordDrillWithRolledChordsToCompletion() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.chordDrill.midiData)
        XCTAssertTrue(song.steps.contains { $0.pitches.count >= 4 })

        let outcome = perform(song, rollEvery: 2)

        assertComplete(outcome, label: "Chord Drill")
        XCTAssertEqual(outcome.engine.stats.stepsCompleted, song.steps.count)
    }

    func testTwinkleFormat0ToCompletion() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.twinkle.midiData)
        XCTAssertEqual(song.format, 0)
        let outcome = perform(song)
        assertComplete(outcome, label: "Twinkle")
    }

    // MARK: - Variations

    func testEachHandAloneToCompletion() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.odeToJoy.midiData)

        for hands in [HandSelection.right, .left] {
            let outcome = perform(song, hands: hands)
            assertComplete(outcome, label: "Ode to Joy \(hands)")
            XCTAssertLessThan(outcome.engine.stats.stepsCompleted, song.steps.count + 1)
        }
    }

    func testSongCompletesAtDifferentSpeeds() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.minuetInG.midiData)
        for speed in [0.5, 2.0] {
            assertComplete(perform(song, speed: speed), label: "Minuet at \(speed)x")
        }
    }

    func testResultsHoldAcrossDifferentPerformances() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.odeToJoy.midiData)
        for seed: UInt64 in [21, 22, 23] {
            assertComplete(perform(song, seed: seed), label: "seed \(seed)")
        }
    }

    // MARK: - Things that must not advance the song

    func testRepeatedNotesRequireARealRestrike() throws {
        // Twinkle opens with C4 C4, and a ringing C4 must not play the second one.
        let song = try MIDIParser.parse(data: BuiltInSongs.twinkle.midiData)
        let room = SimulatedPianoRoom(sampleRate: Self.sampleRate)
        let detector = AcousticPitchDetector()
        var assembler = AudioFrameAssembler()
        let engine = WaitModeEngine(song: song)
        engine.setHandSelection(.right)
        engine.play()
        let hopSeconds = Double(Self.hop) / Self.sampleRate

        func runAudio(seconds: Double) {
            for _ in 0..<Int(seconds / hopSeconds) {
                engine.tick(deltaTime: hopSeconds)
                for frame in assembler.append(room.nextSamples(count: Self.hop)) {
                    engine.ingest(detector.processAudioBuffer(
                        samples: frame,
                        sampleRate: Self.sampleRate,
                        expectedNotes: engine.notesForDetector
                    ))
                }
            }
        }

        runAudio(seconds: 0.5)
        XCTAssertEqual(engine.currentStepIndex, 0)
        XCTAssertEqual(engine.waitingNotes, [60])

        room.strike(60)
        runAudio(seconds: 1)
        XCTAssertEqual(engine.stats.stepsCompleted, 1, "The first C4 was played.")

        // The key stays down: the string rings on through the next step.
        runAudio(seconds: 1.2)
        XCTAssertEqual(engine.currentStepIndex, 1)
        XCTAssertEqual(engine.waitingNotes, [60])
        XCTAssertEqual(engine.stats.stepsCompleted, 1, "A ringing C4 must not play the repeat.")

        room.release(60)
        runAudio(seconds: 0.3)
        room.strike(60)
        runAudio(seconds: 0.5)
        XCTAssertEqual(engine.stats.stepsCompleted, 2, "Striking it again plays the repeat.")
    }

    func testPlayerWhoNeverPlaysNeverAdvances() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.odeToJoy.midiData)
        let room = SimulatedPianoRoom(sampleRate: Self.sampleRate, noiseRMS: 0.01)
        let detector = AcousticPitchDetector()
        var assembler = AudioFrameAssembler()
        let engine = WaitModeEngine(song: song)
        engine.play()
        let hopSeconds = Double(Self.hop) / Self.sampleRate

        for _ in 0..<Int(20 / hopSeconds) {
            engine.tick(deltaTime: hopSeconds)
            for frame in assembler.append(room.nextSamples(count: Self.hop)) {
                engine.ingest(detector.processAudioBuffer(
                    samples: frame,
                    sampleRate: Self.sampleRate,
                    expectedNotes: engine.notesForDetector
                ))
            }
        }

        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.currentStepIndex, 0)
        XCTAssertEqual(engine.stats.stepsCompleted, 0)
        XCTAssertEqual(engine.stats.wrongNotes, 0, "Room noise must not count as wrong notes.")
    }

    // MARK: - Continuous mode

    func testContinuousPerformanceScoresWell() throws {
        let song = try MIDIParser.parse(data: BuiltInSongs.odeToJoy.midiData)
        let room = SimulatedPianoRoom(sampleRate: Self.sampleRate)
        let detector = AcousticPitchDetector()
        var assembler = AudioFrameAssembler()
        let engine = WaitModeEngine(song: song, mode: .continuous)
        engine.play()
        let hopSeconds = Double(Self.hop) / Self.sampleRate

        // The player anticipates by about the detector's latency, as people do when playing along.
        let anticipation = 0.1
        var nextStep = 0
        while engine.state != .finished {
            engine.tick(deltaTime: hopSeconds)
            while nextStep < song.steps.count, engine.playhead + anticipation >= song.steps[nextStep].timeSeconds {
                for note in song.steps[nextStep].pitches {
                    room.release(note)
                }
                let pitches = song.steps[nextStep].pitches
                for note in pitches { room.strike(note) }
                nextStep += 1
            }
            for frame in assembler.append(room.nextSamples(count: Self.hop)) {
                engine.ingest(detector.processAudioBuffer(
                    samples: frame,
                    sampleRate: Self.sampleRate,
                    expectedNotes: engine.notesForDetector
                ))
            }
        }

        XCTAssertEqual(engine.progress, 1)
        XCTAssertGreaterThan(
            Double(engine.stats.notesHit) / Double(engine.stats.notesHit + engine.stats.notesMissed),
            0.8,
            "hit \(engine.stats.notesHit), missed \(engine.stats.notesMissed)"
        )
    }
}
