import Foundation
import XCTest
@testable import PianoWaitCore

final class AcousticPitchDetectorTests: XCTestCase {
    private let generator = TestPianoSignalGenerator()
    private let sampleRate = 44_100.0

    private func note(_ name: String) -> UInt8 {
        MIDINote.parse(name)!
    }

    private func notes(_ names: String...) -> Set<UInt8> {
        Set(names.map(note))
    }

    /// Runs overlapping frames through a fresh detector and returns the last result.
    private func detect(
        _ signal: [Float],
        expected: Set<UInt8> = [],
        frames: Int = 3,
        startingAt offset: TimeInterval = 0.05,
        generator: TestPianoSignalGenerator? = nil
    ) -> PitchDetectionFrameResult {
        let source = generator ?? self.generator
        let detector = AcousticPitchDetector()
        var result = PitchDetectionFrameResult.silent
        for frame in source.frames(of: signal, count: frames, startingAt: offset) {
            result = detector.processAudioBuffer(samples: frame, sampleRate: source.sampleRate, expectedNotes: expected)
        }
        return result
    }

    private func describe(_ set: Set<UInt8>) -> String {
        set.sorted().map(MIDINote.name).joined(separator: " ")
    }

    // MARK: - Single notes

    func testSingleNoteAccuracyAcrossThePianoRange() {
        for name in ["A1", "C2", "G2", "C3", "C4", "A4", "E5", "C6", "G6"] {
            let target = note(name)
            let result = detect(generator.note(target), expected: [target])
            XCTAssertEqual(result.matchedExpectedNotes, [target], "\(name) expected-note match")
            XCTAssertEqual(result.activeNotes, [target], "\(name) heard as \(describe(result.activeNotes))")
        }
    }

    func testEveryKeyInPlayingRangeIsDetectedAsItself() {
        for target in UInt8(33)...UInt8(96) {
            let result = detect(generator.note(target), expected: [target])
            XCTAssertEqual(
                result.activeNotes,
                [target],
                "\(MIDINote.name(target)) heard as \(describe(result.activeNotes))"
            )
        }
    }

    func testExtremeRegisterNotes() {
        for name in ["A0", "E1", "C7", "C8"] {
            let target = note(name)
            XCTAssertTrue(
                detect(generator.note(target), expected: [target]).matchedExpectedNotes.contains(target),
                "\(name) was not detected"
            )
        }
    }

    func testWorksAt48Kilohertz() {
        let generator48 = TestPianoSignalGenerator(sampleRate: 48_000)
        for name in ["A1", "C4", "G6"] {
            let target = note(name)
            let result = detect(generator48.note(target), expected: [target], generator: generator48)
            XCTAssertEqual(result.activeNotes, [target], "\(name) at 48 kHz")
        }
    }

    func testToleratesAnOutOfTunePiano() {
        for cents in [-15.0, 15.0] {
            let target = note("A4")
            let signal = generator.note(target, detuneCents: cents)
            XCTAssertEqual(detect(signal, expected: [target]).matchedExpectedNotes, [target], "\(cents) cents")
        }
    }

    func testDetectsSoftAndLoudPlaying() {
        for velocity: UInt8 in [40, 70, 110, 127] {
            let target = note("C4")
            let signal = generator.note(target, velocity: velocity)
            XCTAssertEqual(detect(signal, expected: [target]).activeNotes, [target], "velocity \(velocity)")
        }
    }

    func testDetectsNotesLateInTheirDecay() {
        let target = note("C4")
        let signal = generator.note(target, duration: 2)
        XCTAssertEqual(detect(signal, expected: [target], startingAt: 1.2).activeNotes, [target])
    }

    // MARK: - Chords

    func testCMajorTriad() {
        let chord = notes("C4", "E4", "G4")
        let result = detect(generator.chord(chord.sorted()), expected: chord)
        XCTAssertEqual(result.matchedExpectedNotes, chord)
        XCTAssertTrue(result.allExpectedMatched)
        XCTAssertEqual(result.activeNotes, chord, "heard \(describe(result.activeNotes))")
    }

    func testDMinorTriad() {
        let chord = notes("D4", "F4", "A4")
        let result = detect(generator.chord(chord.sorted()), expected: chord)
        XCTAssertTrue(result.allExpectedMatched, "matched \(describe(result.matchedExpectedNotes))")
        XCTAssertEqual(result.activeNotes, chord, "heard \(describe(result.activeNotes))")
    }

    func testTwoHandOctaveAndFifthVoicing() {
        let chord = notes("C3", "G3", "E4")
        let result = detect(generator.chord(chord.sorted()), expected: chord)
        XCTAssertTrue(result.allExpectedMatched, "matched \(describe(result.matchedExpectedNotes))")
        XCTAssertEqual(result.activeNotes, chord, "heard \(describe(result.activeNotes))")
    }

    func testRealOctaveIsDetectedRegardlessOfPartialPhases() {
        let chord = notes("C3", "C4")
        for seed: UInt64 in 1...12 {
            let result = detect(generator.chord(chord.sorted(), seed: seed), expected: chord)
            XCTAssertTrue(result.allExpectedMatched, "seed \(seed) matched \(describe(result.matchedExpectedNotes))")
        }
    }

    func testTwoHandChordsThatDoubleANoteAtTheOctave() {
        let chords = [
            notes("C3", "C4", "E4", "G4"), notes("D3", "D4", "F4", "A4"), notes("E3", "E4", "G4", "B4"),
            notes("F3", "F4", "A4", "C5"), notes("G3", "G4", "B4", "D5"), notes("A3", "A4", "C5", "E5"),
            notes("C3", "G3", "C4", "E4", "G4"),
        ]
        for chord in chords {
            for seed: UInt64 in 1...3 {
                let result = detect(generator.chord(chord.sorted(), seed: seed), expected: chord)
                XCTAssertTrue(
                    result.allExpectedMatched,
                    "\(describe(chord)) seed \(seed) matched only \(describe(result.matchedExpectedNotes))"
                )
            }
        }
    }

    func testMissingUpperOctaveIsNotHeardInAChord() {
        // The same chords, but the player leaves out the doubled note.
        let chords: [(played: Set<UInt8>, missing: UInt8)] = [
            (notes("C3", "E4", "G4"), note("C4")),
            (notes("D3", "F4", "A4"), note("D4")),
            (notes("F3", "A4", "C5"), note("F4")),
            (notes("C3", "G3", "C4", "E4"), note("G4")),
            (notes("C3", "G3", "E4", "G4"), note("C4")),
        ]
        for chord in chords {
            let expected = chord.played.union([chord.missing])
            let result = detect(generator.chord(chord.played.sorted()), expected: expected)
            XCTAssertFalse(result.matchedExpectedNotes.contains(chord.missing), MIDINote.name(chord.missing))
            XCTAssertFalse(result.allExpectedMatched)
        }
    }

    func testChordMissingANoteIsNotAComplete() {
        let expected = notes("C4", "E4", "G4")
        let result = detect(generator.chord(notes("C4", "E4").sorted()), expected: expected)
        XCTAssertEqual(result.matchedExpectedNotes, notes("C4", "E4"))
        XCTAssertFalse(result.allExpectedMatched)
    }

    func testChordsAreStableAcrossPartialPhases() {
        let chord = notes("C4", "E4", "G4")
        for seed: UInt64 in 1...12 {
            let result = detect(generator.chord(chord.sorted(), seed: seed), expected: chord)
            XCTAssertEqual(result.matchedExpectedNotes, chord, "seed \(seed)")
        }
    }

    // MARK: - Wrong notes

    func testFSharpDoesNotMatchCMajorTriad() {
        let expected = notes("C4", "E4", "G4")
        let result = detect(generator.note(note("F#4")), expected: expected)
        XCTAssertTrue(result.matchedExpectedNotes.isEmpty, "matched \(describe(result.matchedExpectedNotes))")
        XCTAssertFalse(result.allExpectedMatched)
        XCTAssertEqual(result.activeNotes, notes("F#4"))
    }

    func testDDoesNotMatchC() {
        let result = detect(generator.note(note("D4")), expected: notes("C4"))
        XCTAssertTrue(result.matchedExpectedNotes.isEmpty)
        XCTAssertEqual(result.activeNotes, notes("D4"))
    }

    func testAdjacentSemitonesDoNotMatchAcrossTheRange() {
        for target in stride(from: UInt8(33), through: 90, by: 5) {
            let played = target + 1
            let result = detect(generator.note(played), expected: [target])
            XCTAssertTrue(
                result.matchedExpectedNotes.isEmpty,
                "\(MIDINote.name(played)) falsely matched \(MIDINote.name(target))"
            )
        }
    }

    // MARK: - Octave and harmonic ghosts

    func testC3DoesNotSatisfyC4() {
        let result = detect(generator.note(note("C3")), expected: notes("C4"))
        XCTAssertTrue(result.matchedExpectedNotes.isEmpty, "matched \(describe(result.matchedExpectedNotes))")
        XCTAssertEqual(result.activeNotes, notes("C3"))
    }

    func testOctaveGhostsAreRejectedAcrossTheRange() {
        for lower in stride(from: UInt8(36), through: 72, by: 4) {
            let upper = lower + 12
            let result = detect(generator.note(lower), expected: [upper])
            XCTAssertTrue(
                result.matchedExpectedNotes.isEmpty,
                "\(MIDINote.name(lower)) falsely matched \(MIDINote.name(upper))"
            )
        }
    }

    func testTwelfthGhostIsRejected() {
        // G4 is the third harmonic of C3.
        XCTAssertTrue(detect(generator.note(note("C3")), expected: notes("G4")).matchedExpectedNotes.isEmpty)
    }

    func testSubharmonicGhostIsRejected() {
        // Playing C4 must not satisfy C3, which would share only its even partials.
        XCTAssertTrue(detect(generator.note(note("C4")), expected: notes("C3")).matchedExpectedNotes.isEmpty)
    }

    func testChordDoesNotSatisfyItsMissingFundamental() {
        // C4, E4, and G4 are the 4th, 5th, and 6th harmonics of C2.
        let result = detect(generator.chord(notes("C4", "E4", "G4").sorted()), expected: notes("C2"))
        XCTAssertTrue(result.matchedExpectedNotes.isEmpty)
    }

    // MARK: - Noise

    func testSilenceTriggersNothing() {
        let result = detect(generator.silence(), expected: notes("C4"))
        XCTAssertFalse(result.isAboveNoiseGate)
        XCTAssertTrue(result.activeNotes.isEmpty)
        XCTAssertTrue(result.matchedExpectedNotes.isEmpty)
    }

    func testWhiteNoiseBelowGateTriggersNothing() {
        let result = detect(generator.whiteNoise(rms: 0.001), expected: notes("C4", "E4", "G4"))
        XCTAssertFalse(result.isAboveNoiseGate)
        XCTAssertTrue(result.activeNotes.isEmpty)
    }

    func testLoudNoiseAboveGateStillTriggersNothing() {
        for seed: UInt64 in 1...5 {
            let white = detect(generator.whiteNoise(rms: 0.08, seed: seed), expected: notes("C4", "E4", "G4"))
            XCTAssertTrue(white.isAboveNoiseGate)
            XCTAssertTrue(white.activeNotes.isEmpty, "white noise heard as \(describe(white.activeNotes))")

            let pink = detect(generator.pinkNoise(rms: 0.08, seed: seed), expected: notes("C4", "E4", "G4"))
            XCTAssertTrue(pink.activeNotes.isEmpty, "pink noise heard as \(describe(pink.activeNotes))")
        }
    }

    func testNoteWith20DecibelWhiteNoiseIsDetected() {
        for name in ["C3", "C4", "A4", "C6"] {
            let target = note(name)
            let noisy = generator.addingWhiteNoise(to: generator.note(target), snrDecibels: 20)
            XCTAssertEqual(detect(noisy, expected: [target]).activeNotes, [target], name)
        }
    }

    func testChordWith20DecibelPinkNoiseIsDetected() {
        let chord = notes("C4", "E4", "G4")
        let clean = generator.chord(chord.sorted())
        let noise = generator.pinkNoise(rms: TestPianoSignalGenerator.rms(clean) / 10)
        let result = detect(TestPianoSignalGenerator.mix(clean, noise), expected: chord)
        XCTAssertTrue(result.allExpectedMatched, "matched \(describe(result.matchedExpectedNotes))")
    }

    func testPureToneIsNotAPianoNote() {
        // A whistle or beep at A4 has no harmonic series.
        let result = detect(generator.sine(frequency: 440), expected: notes("A4"))
        XCTAssertTrue(result.matchedExpectedNotes.isEmpty)
        XCTAssertTrue(result.activeNotes.isEmpty)
    }

    func testMainsHumIsNotAPianoNote() {
        let result = detect(generator.sine(frequency: 60, amplitude: 0.2), expected: notes("B1"))
        XCTAssertTrue(result.activeNotes.isEmpty, "hum heard as \(describe(result.activeNotes))")
    }

    func testRaisedGateRejectsQuietNotes() {
        var configuration = AcousticPitchDetector.Configuration()
        configuration.noiseGateRMS = 0.5
        let detector = AcousticPitchDetector(configuration: configuration)
        let frame = generator.frame(of: generator.note(note("C4")))

        let result = detector.processAudioBuffer(samples: frame, sampleRate: sampleRate, expectedNotes: notes("C4"))

        XCTAssertFalse(result.isAboveNoiseGate)
        XCTAssertTrue(result.rawNotes.isEmpty)
    }

    func testNonFiniteSamplesAreHarmless() {
        var frame = generator.frame(of: generator.note(note("C4")))
        frame[100] = .nan
        frame[200] = .infinity
        let result = AcousticPitchDetector().detectActiveNotes(samples: frame, sampleRate: sampleRate)
        XCTAssertTrue(result.contains(note("C4")))
    }

    // MARK: - Debounce and onsets

    func testOneFrameSpikeIsRejected() {
        let detector = AcousticPitchDetector()
        let target = note("C4")
        let spike = generator.frame(of: generator.note(target))
        let silence = generator.frame(of: generator.silence())

        let first = detector.processAudioBuffer(samples: spike, sampleRate: sampleRate, expectedNotes: [target])
        XCTAssertEqual(first.rawNotes, [target], "The frame itself does contain the note.")
        XCTAssertTrue(first.matchedExpectedNotes.isEmpty)
        XCTAssertTrue(first.activeNotes.isEmpty)

        let second = detector.processAudioBuffer(samples: silence, sampleRate: sampleRate, expectedNotes: [target])
        XCTAssertTrue(second.matchedExpectedNotes.isEmpty)

        let third = detector.processAudioBuffer(samples: spike, sampleRate: sampleRate, expectedNotes: [target])
        XCTAssertTrue(third.matchedExpectedNotes.isEmpty, "A gap must restart the count.")
    }

    func testSustainedNoteIsAcceptedOnSecondFrame() {
        let detector = AcousticPitchDetector()
        let target = note("C4")
        let frames = generator.frames(of: generator.note(target), count: 3)

        let first = detector.processAudioBuffer(samples: frames[0], sampleRate: sampleRate, expectedNotes: [target])
        XCTAssertTrue(first.matchedExpectedNotes.isEmpty)

        let second = detector.processAudioBuffer(samples: frames[1], sampleRate: sampleRate, expectedNotes: [target])
        XCTAssertEqual(second.matchedExpectedNotes, [target])
        XCTAssertEqual(second.onsets, [target])

        let third = detector.processAudioBuffer(samples: frames[2], sampleRate: sampleRate, expectedNotes: [target])
        XCTAssertEqual(third.matchedExpectedNotes, [target])
        XCTAssertTrue(third.onsets.isEmpty, "A note reports one onset per strike.")
    }

    func testAttackFramesAreNotTrustedAsEvidence() {
        // A note entering the window from silence smears into false notes, such as G4 for C3.
        let detector = AcousticPitchDetector()
        let room = TestPianoSignalGenerator()
        let leadIn = room.silence(duration: 0.1)
        for name in ["C3", "G2", "D4"] {
            let target = note(name)
            let signal = leadIn + room.note(target)
            detector.reset()
            var position = 0
            while position + TestPianoSignalGenerator.frameSize <= signal.count {
                let frame = Array(signal[position..<(position + TestPianoSignalGenerator.frameSize)])
                let result = detector.processAudioBuffer(samples: frame, sampleRate: sampleRate)
                XCTAssertTrue(result.rawNotes.isSubset(of: [target]), "\(name) heard as \(describe(result.rawNotes))")
                position += TestPianoSignalGenerator.hopSize
            }
        }
    }

    func testBassAndFifthDoNotCreateAPhantomNoteBetweenThem() {
        // Every partial of G3 is an overtone of G2 or D4.
        let result = detect(generator.chord(notes("G2", "D4").sorted()), expected: notes("G3"))
        XCTAssertTrue(result.matchedExpectedNotes.isEmpty, "matched \(describe(result.matchedExpectedNotes))")
        XCTAssertEqual(result.activeNotes, notes("G2", "D4"))
    }

    func testRequiredFrameCountIsConfigurable() {
        var configuration = AcousticPitchDetector.Configuration()
        configuration.requiredConsecutiveFrames = 4
        let detector = AcousticPitchDetector(configuration: configuration)
        let target = note("C4")
        let frames = generator.frames(of: generator.note(target), count: 4)

        let results = frames.map {
            detector.processAudioBuffer(samples: $0, sampleRate: sampleRate, expectedNotes: [target])
        }

        XCTAssertEqual(results.map { !$0.matchedExpectedNotes.isEmpty }, [false, false, false, true])
    }

    func testRingingNoteProducesNoFurtherOnsets() {
        let detector = AcousticPitchDetector()
        let target = note("A4")
        let frames = generator.frames(of: generator.note(target, duration: 2), count: 30)

        let onsets = frames.reduce(0) { count, frame in
            let result = detector.processAudioBuffer(samples: frame, sampleRate: sampleRate, expectedNotes: [target])
            return count + (result.onsets.contains(target) ? 1 : 0)
        }

        XCTAssertEqual(onsets, 1)
    }

    func testRestrikingARingingNoteProducesANewOnset() {
        let detector = AcousticPitchDetector()
        let target = note("A4")
        let tone = generator.note(target, duration: 1.5)
        let signal = Array(tone.prefix(Int(1.0 * sampleRate))) + generator.note(target, duration: 1, seed: 9)
        let hop = TestPianoSignalGenerator.hopSize

        var onsetTimes: [Double] = []
        var position = 4096
        while position + TestPianoSignalGenerator.frameSize <= signal.count {
            let frame = Array(signal[position..<(position + TestPianoSignalGenerator.frameSize)])
            let result = detector.processAudioBuffer(samples: frame, sampleRate: sampleRate, expectedNotes: [target])
            if result.onsets.contains(target) {
                onsetTimes.append(Double(position + TestPianoSignalGenerator.frameSize) / sampleRate)
            }
            position += hop
        }

        XCTAssertEqual(onsetTimes.count, 2, "onsets at \(onsetTimes)")
    }

    func testResetClearsDebounceState() {
        let detector = AcousticPitchDetector()
        let target = note("C4")
        let frames = generator.frames(of: generator.note(target), count: 2)

        _ = detector.processAudioBuffer(samples: frames[0], sampleRate: sampleRate, expectedNotes: [target])
        detector.reset()
        let result = detector.processAudioBuffer(samples: frames[1], sampleRate: sampleRate, expectedNotes: [target])

        XCTAssertTrue(result.matchedExpectedNotes.isEmpty)
    }

    // MARK: - Stateless entry points and buffer handling

    func testDetectExpectedNotesIsStatelessAndTargeted() {
        let detector = AcousticPitchDetector()
        let frame = generator.frame(of: generator.chord(notes("C4", "E4", "G4").sorted()))

        XCTAssertEqual(
            detector.detectExpectedNotes(samples: frame, sampleRate: sampleRate, expectedNotes: notes("C4", "A4")),
            notes("C4")
        )
    }

    func testDetectActiveNotesIsUnconstrained() {
        let frame = generator.frame(of: generator.chord(notes("C4", "E4", "G4").sorted()))
        XCTAssertEqual(
            AcousticPitchDetector().detectActiveNotes(samples: frame, sampleRate: sampleRate),
            notes("C4", "E4", "G4")
        )
    }

    func testBufferSizesOtherThanTheFrameSize() {
        let detector = AcousticPitchDetector()
        let signal = generator.note(note("A4"))

        XCTAssertEqual(detector.detectActiveNotes(samples: Array(signal[2000..<30_000]), sampleRate: sampleRate), notes("A4"))
        XCTAssertEqual(detector.detectActiveNotes(samples: Array(signal[2000..<6000]), sampleRate: sampleRate), notes("A4"))
        XCTAssertTrue(detector.detectActiveNotes(samples: [], sampleRate: sampleRate).isEmpty)
    }

    func testFrameAssemblerProducesOverlappingFrames() {
        var assembler = AudioFrameAssembler(frameSize: 8, hopSize: 2)
        XCTAssertTrue(assembler.append([1]).isEmpty)

        let frames = assembler.append([2, 3, 4, 5])

        XCTAssertEqual(frames, [
            [0, 0, 0, 0, 0, 0, 1, 2],
            [0, 0, 0, 0, 1, 2, 3, 4],
        ])
        XCTAssertEqual(assembler.append([6]).last, [0, 0, 1, 2, 3, 4, 5, 6])
    }

    func testFrameAssemblerResets() {
        var assembler = AudioFrameAssembler(frameSize: 4, hopSize: 2)
        _ = assembler.append([1, 2, 3])
        assembler.reset()
        XCTAssertEqual(assembler.append([9, 9]), [[0, 0, 9, 9]])
    }

    // MARK: - Synthesizer

    func testVoiceBankOutputIsRecognizedAsTheNotePlayed() {
        var bank = PianoVoiceBank(sampleRate: sampleRate)
        bank.noteOn(note: note("C4"))
        bank.noteOn(note: note("E4"))
        bank.noteOn(note: note("G4"))

        var samples = [Float](repeating: 0, count: 16_384)
        samples.withUnsafeMutableBufferPointer { bank.render(into: $0.baseAddress!, frameCount: $0.count) }

        let heard = AcousticPitchDetector().detectActiveNotes(
            samples: Array(samples.suffix(TestPianoSignalGenerator.frameSize)),
            sampleRate: sampleRate
        )
        XCTAssertEqual(heard, notes("C4", "E4", "G4"))
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1, "The output must not clip.")
    }

    func testVoiceBankReleasesNotesAfterTheirDuration() {
        var bank = PianoVoiceBank(sampleRate: sampleRate)
        bank.noteOn(note: note("C4"), duration: 0.05)
        XCTAssertEqual(bank.activeVoiceCount, 1)

        var samples = [Float](repeating: 0, count: 4096)
        for _ in 0..<80 {
            samples.withUnsafeMutableBufferPointer { bank.render(into: $0.baseAddress!, frameCount: $0.count) }
        }

        XCTAssertEqual(bank.activeVoiceCount, 0)
        XCTAssertEqual(samples.map(abs).max() ?? 1, 0, accuracy: 0.001)
    }

    func testVoiceBankStealsAVoiceBeyondItsPolyphony() {
        var bank = PianoVoiceBank(sampleRate: sampleRate)
        for offset in 0..<(PianoVoiceBank.voiceCount + 4) {
            bank.noteOn(note: UInt8(40 + offset))
        }
        XCTAssertEqual(bank.activeVoiceCount, PianoVoiceBank.voiceCount)
    }

    func testLiveTuningTrackerAdaptsToDetunedPianoAndMatchesChords() {
        var config = AcousticPitchDetector.Configuration()
        config.tracksLiveTuning = true
        let detector = AcousticPitchDetector(configuration: config)

        // Simulate a piano that is 25 cents flat across the board.
        let detune = -25.0
        for warmupNote in [note("A4"), note("C4"), note("E4")] {
            for frame in generator.frames(of: generator.note(warmupNote, detuneCents: detune), count: 3) {
                _ = detector.processAudioBuffer(samples: frame, sampleRate: sampleRate, expectedNotes: [warmupNote])
            }
        }
        XCTAssertLessThan(detector.estimatedTuningCents, -10, "Should track flat piano tuning")

        let chordNotes = notes("C4", "E4", "G4", "C5")
        let chordFrames = generator.frames(
            of: generator.chord(chordNotes.sorted(), detuneCents: detune),
            count: 3
        )
        var lastResult: PitchDetectionFrameResult?
        for frame in chordFrames {
            lastResult = detector.processAudioBuffer(samples: frame, sampleRate: sampleRate, expectedNotes: chordNotes)
        }
        XCTAssertEqual(lastResult?.matchedExpectedNotes, chordNotes)
        XCTAssertFalse(lastResult?.topPeaks.isEmpty ?? true)
    }
}
