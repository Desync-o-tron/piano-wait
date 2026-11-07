import Foundation
import XCTest
@testable import PianoWaitCore

final class WaitModeEngineTests: XCTestCase {
    private let c4: UInt8 = 60
    private let d4: UInt8 = 62
    private let e4: UInt8 = 64
    private let f4: UInt8 = 65
    private let g4: UInt8 = 67
    private let c3: UInt8 = 48
    private let e3: UInt8 = 52

    /// Builds a 60 BPM song, so one beat is one second, from (beat, pitch) pairs per hand.
    private func makeSong(
        right: [(beat: Double, pitch: UInt8)],
        left: [(beat: Double, pitch: UInt8)] = [],
        beatsLong: Double = 1
    ) throws -> MIDISong {
        func track(_ notes: [(beat: Double, pitch: UInt8)]) -> MIDIFileBuilder.Track {
            var track = MIDIFileBuilder.Track()
            track.addTempo(beatsPerMinute: 60)
            for note in notes {
                track.addNote(pitch: note.pitch, startTick: Int(note.beat * 480), durationTicks: Int(beatsLong * 480))
            }
            return track
        }
        var tracks = [track(right)]
        if !left.isEmpty { tracks.append(track(left)) }
        return try MIDIParser.parse(data: MIDIFileBuilder(tracks: tracks).build())
    }

    private func makeScale() throws -> MIDISong {
        try makeSong(right: [(1, c4), (2, d4), (3, e4), (4, f4), (5, g4)])
    }

    private func startedEngine(
        _ song: MIDISong,
        mode: PlaybackMode = .waitForMe,
        configuration: WaitModeEngine.Configuration = .init()
    ) -> WaitModeEngine {
        let engine = WaitModeEngine(song: song, mode: mode, configuration: configuration)
        engine.play()
        return engine
    }

    private func run(_ engine: WaitModeEngine, seconds: Double, step: Double = 0.01) {
        for _ in 0..<Int((seconds / step).rounded()) {
            engine.tick(deltaTime: step)
        }
    }

    /// Plays a note the way the microphone reports one: heard, then gone.
    private func hit(_ engine: WaitModeEngine, _ notes: Set<UInt8>) {
        engine.ingest(heard: notes, onsets: notes)
        engine.ingest(heard: [])
    }

    // MARK: - Pausing at steps

    func testPlayheadAdvancesToFirstStepAndPauses() throws {
        let engine = startedEngine(try makeScale())

        run(engine, seconds: 0.5)
        XCTAssertEqual(engine.playhead, 0.5, accuracy: 1e-6)
        XCTAssertEqual(engine.state, .playing)

        run(engine, seconds: 2)
        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-9)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.waitingNotes, [c4])
    }

    func testStepAtTimeZeroWaitsImmediately() throws {
        let engine = startedEngine(try makeSong(right: [(0, c4)]))
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.playhead, 0)
    }

    func testPlayheadStaysPausedDuringSilence() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)

        for _ in 0..<5000 {
            engine.ingest(heard: [])
            engine.tick(deltaTime: 0.05)
        }

        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-9)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.stepStatuses[0], .pending)
    }

    func testPlayheadStaysPausedDuringWrongNotes() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)

        for note: UInt8 in [61, 62, 72, 48, 59, 61, 62] {
            hit(engine, [note])
            run(engine, seconds: 1)
        }

        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-9)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.stats.wrongNotes, 7)
        XCTAssertEqual(engine.stats.stepsCompleted, 0)
    }

    func testPlayheadAdvancesImmediatelyOnceStepIsDetected() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)

        engine.ingest(heard: [c4], onsets: [c4])

        XCTAssertEqual(engine.state, .playing, "The engine must resume in the same call.")
        XCTAssertEqual(engine.stepStatuses[0], .completed)
        XCTAssertEqual(engine.drainEvents(), [.stepCompleted(index: 0)])

        engine.tick(deltaTime: 0.25)
        XCTAssertEqual(engine.playhead, 1.25, accuracy: 1e-9)
    }

    func testPlaysThroughEntireSong() throws {
        let song = try makeScale()
        let engine = startedEngine(song)

        for step in song.steps {
            run(engine, seconds: 1.1)
            XCTAssertEqual(engine.state, .waiting)
            XCTAssertEqual(engine.playhead, step.timeSeconds, accuracy: 1e-9)
            hit(engine, step.pitches)
        }
        run(engine, seconds: 1.1)

        XCTAssertEqual(engine.state, .finished)
        XCTAssertEqual(engine.playhead, song.durationSeconds, accuracy: 1e-9)
        XCTAssertEqual(engine.progress, 1)
        XCTAssertEqual(engine.stats.stepsCompleted, 5)
        XCTAssertEqual(engine.stats.notesHit, 5)
        XCTAssertEqual(engine.stats.accuracy, 1)
    }

    func testPauseStopsThePlayheadAndResumeContinues() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 0.5)

        engine.pause()
        run(engine, seconds: 1)
        XCTAssertEqual(engine.playhead, 0.5, accuracy: 1e-6)

        engine.play()
        run(engine, seconds: 0.25)
        XCTAssertEqual(engine.playhead, 0.75, accuracy: 1e-6)
    }

    func testNotesPlayedWhilePausedDoNotCount() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)

        engine.pause()
        hit(engine, [c4])
        engine.play()

        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.stepStatuses[0], .pending)
    }

    func testLeadInStartsBeforeTheSong() throws {
        var configuration = WaitModeEngine.Configuration()
        configuration.leadIn = 2
        let engine = WaitModeEngine(song: try makeSong(right: [(0, c4)]), configuration: configuration)
        XCTAssertEqual(engine.playhead, -2)

        engine.play()
        XCTAssertEqual(engine.state, .playing)
        run(engine, seconds: 2.1)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.playhead, 0, accuracy: 1e-9)
    }

    func testRestartClearsProgress() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)
        hit(engine, [c4])

        engine.restart()

        XCTAssertEqual(engine.playhead, 0)
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(engine.stats, PracticeStats())
        XCTAssertEqual(engine.stepStatuses, Array(repeating: .pending, count: 5))
        XCTAssertEqual(engine.currentStepIndex, 0)
    }

    // MARK: - Ringing notes

    func testRingingNoteCannotSatisfyARepeatOfItself() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (2, c4)]))
        run(engine, seconds: 1.1)
        engine.ingest(heard: [c4], onsets: [c4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)

        // The string keeps ringing all the way to the next step and beyond.
        for _ in 0..<300 {
            engine.ingest(heard: [c4])
            engine.tick(deltaTime: 0.01)
        }
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.playhead, 2, accuracy: 1e-9)
        XCTAssertEqual(engine.stepStatuses[1], .pending)

        // Striking it again advances.
        engine.ingest(heard: [c4], onsets: [c4])
        XCTAssertEqual(engine.stepStatuses[1], .completed)
    }

    func testReleasedThenReplayedNoteSatisfiesARepeat() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (2, c4)]))
        run(engine, seconds: 1.1)
        engine.ingest(heard: [c4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)

        for _ in 0..<110 {
            engine.ingest(heard: [c4])
            engine.tick(deltaTime: 0.01)
        }
        XCTAssertEqual(engine.stepStatuses[1], .pending)

        engine.ingest(heard: [])
        engine.ingest(heard: [c4])
        XCTAssertEqual(engine.stepStatuses[1], .completed)
    }

    func testNoteStruckJustBeforeArrivalCountsAsEarly() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 0.9)

        engine.ingest(heard: [c4], onsets: [c4])
        XCTAssertEqual(engine.state, .playing)
        run(engine, seconds: 0.15)

        XCTAssertEqual(engine.stepStatuses[0], .completed)
    }

    func testNoteStruckLongBeforeArrivalDoesNotCount() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 0.2)

        engine.ingest(heard: [c4], onsets: [c4])
        run(engine, seconds: 1)

        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.stepStatuses[0], .pending)
    }

    func testStrikeUsedByOneStepIsNotReusedByTheNextWithinTheEarlyWindow() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1.1, c4)]))
        run(engine, seconds: 1.05)

        engine.ingest(heard: [c4], onsets: [c4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)
        run(engine, seconds: 0.2)

        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.stepStatuses[1], .pending)
    }

    // MARK: - Rolled chords

    func testRolledChordLatchesNotesAcrossFrames() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4), (1, g4), (2, c4)]))
        run(engine, seconds: 1.1)

        hit(engine, [c4])
        XCTAssertEqual(engine.latched, [c4])
        XCTAssertEqual(engine.state, .waiting)
        run(engine, seconds: 0.2)

        hit(engine, [e4])
        XCTAssertEqual(engine.latched, [c4, e4])
        XCTAssertEqual(engine.state, .waiting)
        run(engine, seconds: 0.2)

        hit(engine, [g4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.stats.notesHit, 3)
        XCTAssertTrue(engine.latched.isEmpty)
    }

    func testChordPlayedAtOnceCompletesInOneFrame() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4), (1, g4)]))
        run(engine, seconds: 1.1)
        engine.ingest(heard: [c4, e4, g4], onsets: [c4, e4, g4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)
    }

    func testLatchExpiresAfterTheRollWindow() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4), (1, g4)]))
        run(engine, seconds: 1.1)

        hit(engine, [c4])
        XCTAssertEqual(engine.latched, [c4])
        run(engine, seconds: 0.7)
        XCTAssertTrue(engine.latched.isEmpty)

        hit(engine, [e4, g4])
        XCTAssertEqual(engine.state, .waiting, "C4 was too long ago to count.")

        hit(engine, [c4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)
    }

    func testHeldNoteStaysLatchedPastTheRollWindow() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4)]))
        run(engine, seconds: 1.1)

        for _ in 0..<100 {
            engine.ingest(heard: [c4])
            engine.tick(deltaTime: 0.01)
        }
        XCTAssertEqual(engine.latched, [c4])

        engine.ingest(heard: [c4, e4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)
    }

    func testRollWindowIsConfigurable() throws {
        var configuration = WaitModeEngine.Configuration()
        configuration.rollWindow = 2
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4)]), configuration: configuration)
        run(engine, seconds: 1.1)

        hit(engine, [c4])
        run(engine, seconds: 1.5)
        hit(engine, [e4])

        XCTAssertEqual(engine.stepStatuses[0], .completed)
    }

    func testWrongNoteDuringARollKeepsTheLatch() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4)]))
        run(engine, seconds: 1.1)

        hit(engine, [c4])
        hit(engine, [d4])
        XCTAssertEqual(engine.latched, [c4])

        hit(engine, [e4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)
    }

    // MARK: - Hand filtering

    private func makeAlternatingHands() throws -> MIDISong {
        try makeSong(right: [(1, c4), (3, e4)], left: [(2, c3), (4, e3)])
    }

    func testRightHandModeAutoPassesLeftHandSteps() throws {
        let engine = startedEngine(try makeAlternatingHands())
        engine.setHandSelection(.right)

        run(engine, seconds: 1.5)
        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-9)
        XCTAssertEqual(engine.waitingNotes, [c4])
        hit(engine, [c4])

        run(engine, seconds: 3)
        XCTAssertEqual(engine.playhead, 3, accuracy: 1e-9, "The left-hand step at beat 2 must not stop the playhead.")
        XCTAssertEqual(engine.stepStatuses[1], .autoPassed)
        XCTAssertEqual(engine.waitingNotes, [e4])
        hit(engine, [e4])

        run(engine, seconds: 3)
        XCTAssertEqual(engine.state, .finished)
        XCTAssertEqual(engine.stepStatuses, [.completed, .autoPassed, .completed, .autoPassed])
    }

    func testLeftHandModeAutoPassesRightHandSteps() throws {
        let engine = startedEngine(try makeAlternatingHands())
        engine.setHandSelection(.left)

        run(engine, seconds: 2.5)
        XCTAssertEqual(engine.playhead, 2, accuracy: 1e-9)
        XCTAssertEqual(engine.waitingNotes, [c3])
        hit(engine, [c3])

        run(engine, seconds: 3)
        XCTAssertEqual(engine.playhead, 4, accuracy: 1e-9)
        hit(engine, [e3])

        run(engine, seconds: 3)
        XCTAssertEqual(engine.state, .finished)
        XCTAssertEqual(engine.stepStatuses, [.autoPassed, .completed, .autoPassed, .completed])
    }

    func testBothHandsModeWaitsForEveryStep() throws {
        let engine = startedEngine(try makeAlternatingHands())
        for pitch in [c4, c3, e4, e3] {
            run(engine, seconds: 1.5)
            XCTAssertEqual(engine.waitingNotes, [pitch])
            hit(engine, [pitch])
        }
        run(engine, seconds: 1.5)
        XCTAssertEqual(engine.state, .finished)
    }

    func testHandFilterAppliesWithinASharedStep() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4)], left: [(1, c3)]))
        engine.setHandSelection(.right)
        run(engine, seconds: 1.5)

        XCTAssertEqual(engine.waitingNotes, [c4])
        hit(engine, [c4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)
    }

    func testSwitchingHandsWhileWaitingReleasesAStepWithNoNotesForThatHand() throws {
        let engine = startedEngine(try makeAlternatingHands())
        run(engine, seconds: 1.5)
        XCTAssertEqual(engine.state, .waiting)

        engine.setHandSelection(.left)

        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.stepStatuses[0], .autoPassed)
    }

    // MARK: - Accompaniment

    private func playedPitches(_ events: [PracticeEvent]) -> [UInt8] {
        events.compactMap {
            if case .playNote(let pitch, _, _) = $0 { return pitch }
            return nil
        }
    }

    func testAccompanimentPlaysTheOtherHandOnlyWhenEnabled() throws {
        let song = try makeSong(right: [(1, c4)], left: [(1, c3), (2, e3)])

        let silent = startedEngine(song)
        silent.setHandSelection(.right)
        run(silent, seconds: 1.5)
        hit(silent, [c4])
        var events = silent.drainEvents()
        for _ in 0..<150 { events += silent.tick(deltaTime: 0.01) }
        XCTAssertTrue(playedPitches(events).isEmpty)

        let accompanied = startedEngine(song)
        accompanied.setHandSelection(.right)
        accompanied.autoPlayAccompaniment = true
        run(accompanied, seconds: 1.5)
        XCTAssertTrue(playedPitches(accompanied.drainEvents()).isEmpty, "It waits for the player.")
        hit(accompanied, [c4])
        events = accompanied.drainEvents()
        XCTAssertEqual(playedPitches(events), [c3], "It plays together with the completed step.")
        events = []
        for _ in 0..<150 { events += accompanied.tick(deltaTime: 0.01) }
        XCTAssertEqual(playedPitches(events), [e3], "It plays auto-passed steps too.")
    }

    func testAccompanimentIsOffWhenPlayingBothHands() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4)], left: [(1, c3)]))
        engine.autoPlayAccompaniment = true
        run(engine, seconds: 1.5)
        hit(engine, [c4, c3])
        XCTAssertTrue(playedPitches(engine.drainEvents()).isEmpty)
    }

    func testMicrophoneHearingAccompanimentDoesNotCountAsPlaying() throws {
        // The accompaniment plays E4 with step 1, and the player must play E4 in step 2. The low
        // note keeps the left track's average below the right track's.
        let song = try makeSong(right: [(1, 72), (1.5, e4), (1.5, 76)], left: [(1, e4), (3, 36)])
        let engine = startedEngine(song)
        engine.setHandSelection(.right)
        engine.autoPlayAccompaniment = true
        run(engine, seconds: 1.1)
        hit(engine, [72])
        XCTAssertEqual(playedPitches(engine.drainEvents()), [e4])

        run(engine, seconds: 0.6)
        XCTAssertEqual(engine.state, .waiting)
        engine.ingest(heard: [e4, 76], onsets: [e4, 76])

        XCTAssertEqual(engine.state, .waiting, "That E4 came from the speaker.")
    }

    // MARK: - Speed

    func testSpeedScalesPlayheadDelta() throws {
        for speed in [0.25, 0.5, 1.0, 1.5, 2.0] {
            let engine = startedEngine(try makeSong(right: [(100, c4)]))
            engine.setSpeed(speed)

            for _ in 0..<100 { engine.tick(deltaTime: 0.01) }

            XCTAssertEqual(engine.playhead, speed, accuracy: 1e-6, "speed \(speed)")
        }
    }

    func testMidPlaybackSpeedChangeKeepsPosition() throws {
        let engine = startedEngine(try makeSong(right: [(100, c4)]))

        run(engine, seconds: 1)
        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-6)

        engine.setSpeed(0.5)
        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-6, "Changing speed must not move the playhead.")
        run(engine, seconds: 1)
        XCTAssertEqual(engine.playhead, 1.5, accuracy: 1e-6)

        engine.setSpeed(2)
        run(engine, seconds: 1)
        XCTAssertEqual(engine.playhead, 3.5, accuracy: 1e-6)
    }

    func testSpeedClampsToSupportedRange() throws {
        let engine = startedEngine(try makeScale())
        engine.setSpeed(0.01)
        XCTAssertEqual(engine.speed, 0.25)
        engine.setSpeed(9)
        XCTAssertEqual(engine.speed, 2)
    }

    func testRollWindowRunsOnRealTimeAtAnySpeed() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4)]))
        engine.setSpeed(2)
        run(engine, seconds: 0.6)
        hit(engine, [c4])

        run(engine, seconds: 0.5)
        XCTAssertEqual(engine.latched, [c4], "0.5 real seconds is inside the window even at double speed.")
    }

    func testLargeTickStopsExactlyAtTheStep() throws {
        let engine = startedEngine(try makeScale())
        engine.tick(deltaTime: 50)
        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-9)
        XCTAssertEqual(engine.state, .waiting)
    }

    // MARK: - Skipping

    func testSkipAdvancesPastAStep() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)

        engine.skipStep()

        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.stepStatuses[0], .skipped)
        XCTAssertEqual(engine.stats.stepsSkipped, 1)
        XCTAssertEqual(engine.stats.notesMissed, 1)
        XCTAssertEqual(engine.stats.stepsCompleted, 0)
        XCTAssertEqual(engine.currentStepIndex, 1)
    }

    func testSkipCreditsLatchedNotesAndResetsStreak() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (2, c4), (2, e4)]))
        run(engine, seconds: 1.5)
        hit(engine, [c4])
        XCTAssertEqual(engine.stats.currentStreak, 1)
        run(engine, seconds: 1.5)
        hit(engine, [c4])

        engine.skipStep()

        XCTAssertEqual(engine.stats.currentStreak, 0)
        XCTAssertEqual(engine.stats.notesHit, 2)
        XCTAssertEqual(engine.stats.notesMissed, 1)
    }

    func testSkippingTheLastStepFinishesTheSong() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4)]))
        run(engine, seconds: 1.5)

        engine.skipStep()
        run(engine, seconds: 1.5)

        XCTAssertEqual(engine.state, .finished)
    }

    func testKeyPressPlaysAStep() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)

        engine.registerKeyPress(d4)
        XCTAssertEqual(engine.state, .waiting)

        engine.registerKeyPress(c4)
        XCTAssertEqual(engine.stepStatuses[0], .completed)
    }

    func testMicrophoneHearingATappedKeyDoesNotPlayItAgain() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1.2, c4)]))
        run(engine, seconds: 1.1)

        engine.registerKeyPress(c4)
        XCTAssertEqual(engine.stepStatuses[0], .completed)
        run(engine, seconds: 0.2)
        XCTAssertEqual(engine.state, .waiting)

        // The speaker's sound of that tap reaches the microphone.
        engine.ingest(heard: [c4], onsets: [c4])
        XCTAssertEqual(engine.stepStatuses[1], .pending)
        XCTAssertEqual(engine.stats.wrongNotes, 0)
    }

    // MARK: - A-B looping

    func testLoopResetsPlayheadAndRequiresStepsToBePlayedAgain() throws {
        let engine = startedEngine(try makeScale())
        XCTAssertTrue(engine.setLoop(start: 0.5, end: 3))
        XCTAssertEqual(engine.playhead, 0.5, accuracy: 1e-9, "The playhead starts at A.")

        run(engine, seconds: 0.6)
        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-9)
        hit(engine, [c4])
        run(engine, seconds: 1.1)
        XCTAssertEqual(engine.playhead, 2, accuracy: 1e-9)
        hit(engine, [d4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)
        XCTAssertEqual(engine.stepStatuses[1], .completed)

        // The step at beat 3 sits exactly on B, so reaching it loops rather than waits.
        var events: [PracticeEvent] = []
        for _ in 0..<110 { events += engine.tick(deltaTime: 0.01) }

        XCTAssertTrue(events.contains(.looped))
        XCTAssertEqual(engine.stepStatuses[0], .pending, "Steps inside the loop must be played again.")
        XCTAssertEqual(engine.stepStatuses[1], .pending)
        XCTAssertEqual(engine.stepStatuses[2], .pending)
        XCTAssertLessThan(engine.playhead, 1)

        run(engine, seconds: 1)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.waitingNotes, [c4])
        XCTAssertEqual(engine.playhead, 1, accuracy: 1e-9)
    }

    func testLoopRepeatsManyTimes() throws {
        let engine = startedEngine(try makeScale())
        engine.setLoop(start: 0.5, end: 1.5)
        var loops = 0

        for _ in 0..<4 {
            run(engine, seconds: 0.6)
            XCTAssertEqual(engine.waitingNotes, [c4])
            hit(engine, [c4])
            var events = engine.drainEvents()
            for _ in 0..<60 { events += engine.tick(deltaTime: 0.01) }
            loops += events.filter { $0 == .looped }.count
            engine.tick(deltaTime: 0)
            if engine.playhead < 0.5 { break }
            engine.seek(to: 0.5)
        }

        XCTAssertGreaterThanOrEqual(loops, 4)
        XCTAssertEqual(engine.stats.stepsCompleted, 4, "Statistics accumulate across passes.")
    }

    func testStepsOutsideTheLoopAreUntouched() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)
        hit(engine, [c4])

        engine.setLoop(start: 1.5, end: 3)
        run(engine, seconds: 0.6)
        hit(engine, [d4])
        run(engine, seconds: 1.1)

        XCTAssertEqual(engine.stepStatuses[0], .completed)
        XCTAssertEqual(engine.stepStatuses[1], .pending)
    }

    func testInvalidLoopIsRejected() throws {
        let engine = startedEngine(try makeScale())
        XCTAssertFalse(engine.setLoop(start: 3, end: 2))
        XCTAssertFalse(engine.setLoop(start: 2, end: 2))
        XCTAssertFalse(engine.setLoop(start: 99, end: 100))
        XCTAssertNil(engine.loopRange)
    }

    func testClearLoopStopsLooping() throws {
        let engine = startedEngine(try makeSong(right: [(100, c4)]))
        engine.setLoop(start: 0, end: 1)
        engine.clearLoop()
        run(engine, seconds: 2)
        XCTAssertEqual(engine.playhead, 2, accuracy: 1e-6)
    }

    func testLoopFromBars() throws {
        var track = MIDIFileBuilder.Track()
        track.addTempo(beatsPerMinute: 60)
        track.addTimeSignature(numerator: 4, denominator: 4)
        for bar in 0..<4 {
            track.addNote(pitch: 60, startTick: bar * 480 * 4, durationTicks: 480)
        }
        let engine = startedEngine(try MIDIParser.parse(data: MIDIFileBuilder(tracks: [track]).build()))

        XCTAssertTrue(engine.setLoop(startBar: 2, endBar: 3))
        XCTAssertEqual(engine.loopRange, 4...12)
        XCTAssertFalse(engine.setLoop(startBar: 3, endBar: 2))
        XCTAssertFalse(engine.setLoop(startBar: 0, endBar: 2))
    }

    func testLoopWorksAtDifferentSpeeds() throws {
        let engine = startedEngine(try makeSong(right: [(100, c4)]))
        engine.setLoop(start: 1, end: 2)
        engine.setSpeed(2)

        var events: [PracticeEvent] = []
        for _ in 0..<60 { events += engine.tick(deltaTime: 0.01) }

        XCTAssertEqual(events.filter { $0 == .looped }.count, 1)
        XCTAssertEqual(engine.playhead, 1.2, accuracy: 1e-6)
    }

    // MARK: - Seeking

    func testSeekResetsLaterSteps() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)
        hit(engine, [c4])
        run(engine, seconds: 1.5)
        hit(engine, [d4])

        engine.seek(to: 1.5)

        XCTAssertEqual(engine.stepStatuses[0], .completed)
        XCTAssertEqual(engine.stepStatuses[1], .pending)
        XCTAssertEqual(engine.currentStepIndex, 1)
    }

    // MARK: - Statistics

    func testStreakTracksConsecutiveCleanSteps() throws {
        let song = try makeScale()
        let engine = startedEngine(song)

        run(engine, seconds: 1.5)
        hit(engine, [c4])
        run(engine, seconds: 1.5)
        hit(engine, [d4])
        XCTAssertEqual(engine.stats.currentStreak, 2)

        run(engine, seconds: 1.5)
        hit(engine, [72])
        XCTAssertEqual(engine.stats.currentStreak, 0)
        XCTAssertEqual(engine.stats.bestStreak, 2)

        hit(engine, [e4])
        XCTAssertEqual(engine.stats.currentStreak, 1)
        XCTAssertEqual(engine.stats.bestStreak, 2)
        XCTAssertEqual(engine.stats.stepsCompleted, 3)
    }

    func testAccuracyCountsWrongNotes() throws {
        let engine = startedEngine(try makeScale())
        XCTAssertEqual(engine.stats.accuracy, 1)

        run(engine, seconds: 1.5)
        hit(engine, [72])
        hit(engine, [c4])

        XCTAssertEqual(engine.stats.notesHit, 1)
        XCTAssertEqual(engine.stats.wrongNotes, 1)
        XCTAssertEqual(engine.stats.accuracy, 0.5, accuracy: 1e-9)
    }

    // MARK: - Continuous mode

    func testContinuousModeNeverPauses() throws {
        let song = try makeScale()
        let engine = startedEngine(song, mode: .continuous)

        run(engine, seconds: song.durationSeconds + 0.1)

        XCTAssertEqual(engine.state, .finished)
        XCTAssertEqual(engine.stats.notesMissed, 5)
        XCTAssertEqual(engine.stats.stepsCompleted, 0)
        XCTAssertEqual(engine.stepStatuses, Array(repeating: .missed, count: 5))
    }

    func testContinuousModeAdvancesAtScaledTempo() throws {
        let engine = startedEngine(try makeScale(), mode: .continuous)
        engine.setSpeed(1.5)
        run(engine, seconds: 2)
        XCTAssertEqual(engine.playhead, 3, accuracy: 1e-6)
        XCTAssertEqual(engine.state, .playing)
    }

    func testContinuousModeScoresNotesPlayedOnTime() throws {
        let song = try makeScale()
        let engine = startedEngine(song, mode: .continuous)

        var played = 0
        while engine.state != .finished {
            engine.tick(deltaTime: 0.01)
            if played < song.steps.count, engine.playhead >= song.steps[played].timeSeconds {
                hit(engine, song.steps[played].pitches)
                played += 1
            }
        }

        XCTAssertEqual(engine.stats.stepsCompleted, 5)
        XCTAssertEqual(engine.stats.notesHit, 5)
        XCTAssertEqual(engine.stats.notesMissed, 0)
        XCTAssertEqual(engine.stats.wrongNotes, 0)
        XCTAssertEqual(engine.stats.currentStreak, 5)
    }

    func testContinuousModeAcceptsSlightlyEarlyAndLateNotes() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (2, d4)]), mode: .continuous)

        run(engine, seconds: 0.85)
        hit(engine, [c4])
        XCTAssertEqual(engine.stepStatuses[0], .completed, "0.15s early")

        run(engine, seconds: 1.3)
        hit(engine, [d4])
        XCTAssertEqual(engine.stepStatuses[1], .completed, "0.15s late")
    }

    func testContinuousModeCountsMissesAndWrongNotes() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (3, d4)]), mode: .continuous)

        run(engine, seconds: 1)
        hit(engine, [72])
        XCTAssertEqual(engine.stats.wrongNotes, 1)

        run(engine, seconds: 0.5)
        XCTAssertEqual(engine.stepStatuses[0], .missed)
        XCTAssertEqual(engine.stats.notesMissed, 1)
        XCTAssertEqual(engine.state, .playing)
    }

    func testContinuousPartialChordScoresThePartThatWasHit() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4), (3, d4)]), mode: .continuous)

        run(engine, seconds: 1)
        hit(engine, [c4])
        run(engine, seconds: 0.5)

        XCTAssertEqual(engine.stats.notesHit, 1)
        XCTAssertEqual(engine.stats.notesMissed, 1)
        XCTAssertEqual(engine.stepStatuses[0], .missed)
    }

    func testContinuousLoopRescoresSteps() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (5, d4)]), mode: .continuous)
        engine.setLoop(start: 0, end: 2)

        run(engine, seconds: 1)
        hit(engine, [c4])
        XCTAssertEqual(engine.stepStatuses[0], .completed)

        run(engine, seconds: 1.1)
        XCTAssertEqual(engine.stepStatuses[0], .pending)
    }

    func testReferenceAudioPlaysAllNotesInContinuousMode() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4)], left: [(1, c3)]), mode: .continuous)
        engine.playsReferenceAudio = true

        var events: [PracticeEvent] = []
        for _ in 0..<110 { events += engine.tick(deltaTime: 0.01) }

        XCTAssertEqual(Set(playedPitches(events)), [c4, c3])
    }

    func testPlayEventDurationScalesWithSpeed() throws {
        let engine = startedEngine(try makeSong(right: [(0.5, c4)]), mode: .continuous)
        engine.playsReferenceAudio = true
        engine.setSpeed(2)

        var events: [PracticeEvent] = []
        for _ in 0..<40 { events += engine.tick(deltaTime: 0.01) }

        guard case .playNote(_, _, let duration)? = events.first(where: {
            if case .playNote = $0 { return true }
            return false
        }) else {
            return XCTFail("No note was played.")
        }
        XCTAssertEqual(duration, 0.5, accuracy: 1e-3)
    }

    func testSwitchingModesMidSongContinues() throws {
        let engine = startedEngine(try makeScale())
        run(engine, seconds: 1.5)
        XCTAssertEqual(engine.state, .waiting)

        engine.setMode(.continuous)
        run(engine, seconds: 0.5)

        XCTAssertEqual(engine.state, .playing)
        XCTAssertGreaterThan(engine.playhead, 1)
    }

    func testDetectorTargetsFollowTheEngine() throws {
        let engine = startedEngine(try makeSong(right: [(1, c4), (1, e4), (2, g4)]))
        XCTAssertEqual(engine.notesForDetector, [c4, e4])
        run(engine, seconds: 1.5)
        hit(engine, [c4, e4])
        XCTAssertEqual(engine.notesForDetector, [g4])
    }

    func testStrikeMemoryCompletesCloselySpacedRollStepPlayedTogether() throws {
        var config = WaitModeEngine.Configuration()
        config.strikeMemorySeconds = 0.85
        let engine = startedEngine(
            try makeSong(right: [(1.0, 66), (1.0, 69), (1.0, 75), (1.04, 71)]),
            configuration: config
        )
        run(engine, seconds: 1.0)
        XCTAssertEqual(engine.currentStepIndex, 0)
        XCTAssertEqual(engine.notesForDetector, [66, 69, 71, 75])

        // Player strikes all four notes of the rolled chord together.
        engine.ingest(heard: [66, 69, 71, 75], onsets: [66, 69, 71, 75])
        XCTAssertEqual(engine.stepStatuses[0], .completed)

        // When the playhead advances 40ms to the next step, B4 (71) is already satisfied.
        run(engine, seconds: 0.05)
        XCTAssertEqual(engine.stepStatuses[1], .completed)
    }
}
