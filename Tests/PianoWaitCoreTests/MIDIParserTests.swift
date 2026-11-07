import Foundation
import XCTest
@testable import PianoWaitCore

final class MIDIParserTests: XCTestCase {
    // MARK: - Fixture helpers

    private func header(format: UInt16 = 0, tracks: UInt16 = 1, division: UInt16 = 480) -> [UInt8] {
        Array("MThd".utf8) + [0, 0, 0, 6]
            + [UInt8(format >> 8), UInt8(format & 0xFF)]
            + [UInt8(tracks >> 8), UInt8(tracks & 0xFF)]
            + [UInt8(division >> 8), UInt8(division & 0xFF)]
    }

    private func track(_ events: [UInt8], endOfTrack: Bool = true) -> [UInt8] {
        let body = events + (endOfTrack ? [0x00, 0xFF, 0x2F, 0x00] : [])
        let length = UInt32(body.count)
        return Array("MTrk".utf8) + [
            UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF),
        ] + body
    }

    private func parse(_ bytes: [UInt8]) throws -> MIDISong {
        try MIDIParser.parse(data: Data(bytes))
    }

    private let tempo60: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40]
    private let tempo120: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]

    // MARK: - Formats

    func testParsesFormat0() throws {
        let song = try parse(header() + track(tempo120 + [
            0x00, 0x90, 60, 80,
            0x83, 0x60, 0x80, 60, 0,
        ]))

        XCTAssertEqual(song.format, 0)
        XCTAssertEqual(song.notes.count, 1)
        XCTAssertEqual(song.notes[0].pitch, 60)
        XCTAssertEqual(song.notes[0].velocity, 80)
        XCTAssertEqual(song.notes[0].startSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(song.notes[0].endSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(song.durationSeconds, 0.5, accuracy: 1e-9)
    }

    func testParsesFormat1WithConductorTrack() throws {
        let conductor = track(tempo60)
        let melody = track([0x00, 0x90, 72, 80, 0x83, 0x60, 0x80, 72, 0])
        let bass = track([0x00, 0x90, 48, 80, 0x83, 0x60, 0x80, 48, 0])
        let song = try parse(header(format: 1, tracks: 3) + conductor + melody + bass)

        XCTAssertEqual(song.format, 1)
        XCTAssertEqual(song.notes.count, 2)
        XCTAssertEqual(song.notes[0].endSeconds, 1, accuracy: 1e-9, "The conductor's tempo must apply to every track.")
        XCTAssertEqual(song.steps.count, 1)
    }

    func testSkipsUnknownChunks() throws {
        let unknown = Array("XFIH".utf8) + [0, 0, 0, 3, 1, 2, 3]
        let song = try parse(header() + unknown + track([0x00, 0x90, 60, 80, 0x60, 0x80, 60, 0]))
        XCTAssertEqual(song.notes.count, 1)
    }

    func testBuilderRoundTrip() throws {
        var track = MIDIFileBuilder.Track(name: "Round Trip")
        track.addTempo(beatsPerMinute: 90)
        track.addTimeSignature(numerator: 3, denominator: 4)
        track.addNote(pitch: 64, startTick: 480, durationTicks: 240, velocity: 100)

        let song = try MIDIParser.parse(data: MIDIFileBuilder(tracks: [track]).build())

        XCTAssertEqual(song.title, "Round Trip")
        XCTAssertEqual(song.notes.first?.pitch, 64)
        XCTAssertEqual(song.notes.first?.velocity, 100)
        XCTAssertEqual(song.notes.first?.startSeconds ?? 0, 60 / 90, accuracy: 1e-3)
    }

    // MARK: - Variable-length quantities

    func testVariableLengthQuantityEdgeCases() throws {
        let cases: [(bytes: [UInt8], ticks: Int)] = [
            ([0x00], 0),
            ([0x7F], 127),
            ([0x81, 0x00], 128),
            ([0xFF, 0x7F], 16_383),
            ([0x81, 0x80, 0x00], 16_384),
            ([0xFF, 0xFF, 0x7F], 2_097_151),
            ([0x81, 0x80, 0x80, 0x00], 2_097_152),
            ([0xFF, 0xFF, 0xFF, 0x7F], 268_435_455),
        ]

        for testCase in cases {
            let song = try parse(header() + track(testCase.bytes + [0x90, 60, 80] + [0x10, 0x80, 60, 0]))
            XCTAssertEqual(song.notes[0].startTick, testCase.ticks, "VLQ bytes \(testCase.bytes)")
        }
    }

    func testRejectsFiveByteVariableLengthQuantity() {
        XCTAssertThrowsError(try parse(header() + track([0x81, 0x80, 0x80, 0x80, 0x00, 0x90, 60, 80]))) {
            XCTAssertEqual($0 as? MIDIParseError, .invalidVariableLengthQuantity)
        }
    }

    func testBuilderEncodesVariableLengthQuantities() {
        XCTAssertEqual(MIDIFileBuilder.variableLengthQuantity(0), [0x00])
        XCTAssertEqual(MIDIFileBuilder.variableLengthQuantity(127), [0x7F])
        XCTAssertEqual(MIDIFileBuilder.variableLengthQuantity(128), [0x81, 0x00])
        XCTAssertEqual(MIDIFileBuilder.variableLengthQuantity(0x0FFF_FFFF), [0xFF, 0xFF, 0xFF, 0x7F])
    }

    // MARK: - Events

    func testRunningStatus() throws {
        let song = try parse(header() + track([
            0x00, 0x90, 60, 80,
            0x00, 64, 81,
            0x00, 67, 82,
            0x60, 60, 0,
            0x00, 64, 0,
            0x00, 67, 0,
        ]))

        XCTAssertEqual(song.notes.map(\.pitch), [60, 64, 67])
        XCTAssertEqual(song.notes.map(\.velocity), [80, 81, 82])
        XCTAssertEqual(song.steps.count, 1)
        XCTAssertGreaterThan(song.notes[0].durationSeconds, 0)
    }

    func testDataByteWithoutRunningStatusThrows() {
        XCTAssertThrowsError(try parse(header() + track([0x00, 60, 80]))) {
            XCTAssertEqual($0 as? MIDIParseError, .missingRunningStatus)
        }
    }

    func testNoteOnWithZeroVelocityEndsTheNote() throws {
        let song = try parse(header() + track(tempo120 + [
            0x00, 0x90, 60, 80,
            0x83, 0x60, 0x90, 60, 0,
        ]))

        XCTAssertEqual(song.notes.count, 1)
        XCTAssertEqual(song.notes[0].endSeconds, 0.5, accuracy: 1e-9)
    }

    func testOverlappingNotesOfOnePitchCloseFirstInFirstOut() throws {
        let song = try parse(header() + track(tempo120 + [
            0x00, 0x90, 60, 80,
            0x83, 0x60, 0x90, 60, 70,
            0x83, 0x60, 0x80, 60, 0,
            0x83, 0x60, 0x80, 60, 0,
        ]))

        XCTAssertEqual(song.notes.count, 2)
        XCTAssertEqual(song.notes[0].endSeconds, 1.0, accuracy: 1e-9)
        XCTAssertEqual(song.notes[1].endSeconds, 1.5, accuracy: 1e-9)
    }

    func testUnterminatedNoteRingsToTrackEnd() throws {
        let song = try parse(header() + track(tempo120 + [
            0x00, 0x90, 60, 80,
            0x83, 0x60, 0xFF, 0x2F, 0x00,
        ], endOfTrack: false))

        XCTAssertEqual(song.notes.count, 1)
        XCTAssertEqual(song.notes[0].endSeconds, 0.5, accuracy: 1e-9)
    }

    func testIgnoresOtherChannelMessagesSysexAndMeta() throws {
        let song = try parse(header() + track([
            0x00, 0xB0, 64, 127,
            0x00, 0xC0, 5,
            0x00, 0xD0, 30,
            0x00, 0xE0, 0, 64,
            0x00, 0xF0, 0x03, 0x41, 0x42, 0xF7,
            0x00, 0xFF, 0x7F, 0x02, 0x01, 0x02,
            0x00, 0x90, 60, 80,
            0x60, 0x80, 60, 0,
        ]))
        XCTAssertEqual(song.notes.map(\.pitch), [60])
    }

    func testDropsPercussionAndNotesOutsideThePiano() throws {
        let song = try parse(header() + track([
            0x00, 0x99, 60, 80, 0x10, 0x89, 60, 0,
            0x00, 0x90, 20, 80, 0x10, 0x80, 20, 0,
            0x00, 0x90, 109, 80, 0x10, 0x80, 109, 0,
            0x00, 0x90, 21, 80, 0x10, 0x80, 21, 0,
            0x00, 0x90, 108, 80, 0x10, 0x80, 108, 0,
        ]))

        XCTAssertEqual(Set(song.notes.map(\.pitch)), [21, 108])
        XCTAssertEqual(song.droppedNoteCount, 3)
    }

    // MARK: - Meta events and timing

    func testMidPieceTempoChangesConvertAccurately() throws {
        let song = try parse(header() + track(tempo120 + [
            0x00, 0x90, 60, 80,
            0x83, 0x60, 0x80, 60, 0,        // One beat at 120 BPM: ends at 0.5s.
            0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40, // Now 60 BPM.
            0x00, 0x90, 62, 80,
            0x83, 0x60, 0x80, 62, 0,        // One beat at 60 BPM: ends at 1.5s.
            0x00, 0xFF, 0x51, 0x03, 0x03, 0xD0, 0x90, // Now 240 BPM.
            0x00, 0x90, 64, 80,
            0x83, 0x60, 0x80, 64, 0,        // One beat at 240 BPM: ends at 1.75s.
        ]))

        XCTAssertEqual(song.notes[1].startSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(song.notes[1].endSeconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(song.notes[2].startSeconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(song.notes[2].endSeconds, 1.75, accuracy: 1e-9)
        XCTAssertEqual(song.tempoEvents.map(\.beatsPerMinute).map { $0.rounded() }, [120, 60, 240])
    }

    func testDefaultTempoIs120BeatsPerMinute() throws {
        let song = try parse(header() + track([0x00, 0x90, 60, 80, 0x83, 0x60, 0x80, 60, 0]))
        XCTAssertEqual(song.durationSeconds, 0.5, accuracy: 1e-9)
    }

    func testTempoInLaterTrackAppliesToEarlierTracks() throws {
        let notes = track([0x83, 0x60, 0x90, 60, 80, 0x83, 0x60, 0x80, 60, 0])
        let tempos = track([0x83, 0x60, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40])
        let song = try parse(header(format: 1, tracks: 2) + notes + tempos)
        XCTAssertEqual(song.notes[0].startSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(song.notes[0].endSeconds, 1.5, accuracy: 1e-9)
    }

    func testSMPTEDivision() throws {
        // -25 frames per second at 40 ticks per frame gives 1000 ticks per second.
        let division = UInt16(UInt8(bitPattern: -25)) << 8 | 40
        let song = try parse(header(division: division) + track([
            0x87, 0x68, 0x90, 60, 80,
            0x87, 0x68, 0x80, 60, 0,
        ]))

        XCTAssertEqual(song.notes[0].startSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(song.notes[0].endSeconds, 2, accuracy: 1e-9)
    }

    func testReadsTimeSignatureAndTrackName() throws {
        let song = try parse(header() + track([
            0x00, 0xFF, 0x03, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F,
            0x00, 0xFF, 0x58, 0x04, 6, 3, 24, 8,
            0x00, 0x90, 60, 80,
            0x60, 0x80, 60, 0,
        ]))

        XCTAssertEqual(song.title, "Hello")
        XCTAssertEqual(song.trackNames, ["Hello"])
        XCTAssertEqual(song.timeSignatures.first?.numerator, 6)
        XCTAssertEqual(song.timeSignatures.first?.denominator, 8)
    }

    func testExplicitTitleOverridesTrackName() throws {
        let bytes = header() + track([
            0x00, 0xFF, 0x03, 0x01, 0x41,
            0x00, 0x90, 60, 80,
            0x60, 0x80, 60, 0,
        ])
        XCTAssertEqual(try MIDIParser.parse(data: Data(bytes), title: "Mine").title, "Mine")
    }

    func testBarStartsFollowTimeSignatureChanges() throws {
        var builder = MIDIFileBuilder.Track()
        builder.addTempo(beatsPerMinute: 60)
        builder.addTimeSignature(numerator: 4, denominator: 4)
        builder.addTimeSignature(numerator: 3, denominator: 4, tick: 480 * 4)
        builder.addNote(pitch: 60, startTick: 480 * 10, durationTicks: 480)

        let song = try MIDIParser.parse(data: MIDIFileBuilder(tracks: [builder]).build())

        XCTAssertEqual(song.barStartSeconds, [0, 4, 7, 10])
    }

    // MARK: - Chord grouping

    private func song(startsInSeconds starts: [Double], chordWindow: TimeInterval = MIDIParser.defaultChordWindow) throws -> MIDISong {
        var builder = MIDIFileBuilder.Track()
        builder.addTempo(beatsPerMinute: 60)
        for (index, start) in starts.enumerated() {
            builder.addNote(pitch: UInt8(60 + index), startTick: Int(start * 480), durationTicks: 100)
        }
        return try MIDIParser.parse(data: MIDIFileBuilder(tracks: [builder]).build(), chordWindow: chordWindow)
    }

    func testGroupsSimultaneousNotesIntoOneStep() throws {
        let result = try song(startsInSeconds: [0, 0, 0, 1])
        XCTAssertEqual(result.steps.map(\.notes.count), [3, 1])
        XCTAssertEqual(result.steps[0].pitches, [60, 61, 62])
        XCTAssertEqual(result.steps[1].timeSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(result.steps.map(\.index), [0, 1])
    }

    func testGroupsNearSimultaneousNotesWithinDefaultWindow() throws {
        XCTAssertEqual(try song(startsInSeconds: [0, 0.03]).steps.count, 1)
        XCTAssertEqual(try song(startsInSeconds: [0, 0.05]).steps.count, 2)
    }

    func testChordWindowIsConfigurable() throws {
        XCTAssertEqual(try song(startsInSeconds: [0, 0.05], chordWindow: 0.1).steps.count, 1)
        XCTAssertEqual(try song(startsInSeconds: [0, 0.02], chordWindow: 0.001).steps.count, 2)
    }

    func testFastRunDoesNotChainIntoOneChord() throws {
        let result = try song(startsInSeconds: [0, 0.025, 0.05, 0.075, 0.1])
        XCTAssertGreaterThan(result.steps.count, 1)
        for step in result.steps {
            let times = step.notes.map(\.startSeconds)
            XCTAssertLessThanOrEqual((times.max() ?? 0) - (times.min() ?? 0), MIDIParser.defaultChordWindow)
        }
    }

    // MARK: - Hand assignment

    func testFormat1AssignsTracksByAveragePitch() throws {
        var low = MIDIFileBuilder.Track()
        low.addTempo(beatsPerMinute: 120)
        // Crosses middle C, so only the track average can put this in the left hand.
        low.addNote(pitch: 48, startTick: 0, durationTicks: 100)
        low.addNote(pitch: 62, startTick: 480, durationTicks: 100)
        var high = MIDIFileBuilder.Track()
        high.addNote(pitch: 72, startTick: 0, durationTicks: 100)
        high.addNote(pitch: 58, startTick: 480, durationTicks: 100)
        high.addNote(pitch: 76, startTick: 960, durationTicks: 100)

        let song = try MIDIParser.parse(data: MIDIFileBuilder(tracks: [low, high]).build())
        let hands = Dictionary(uniqueKeysWithValues: song.notes.map { ($0.pitch, $0.hand) })

        XCTAssertEqual(hands[48], .left)
        XCTAssertEqual(hands[62], .left)
        XCTAssertEqual(hands[72], .right)
        XCTAssertEqual(hands[58], .right)
    }

    func testTrackOrderDoesNotDecideHands() throws {
        var high = MIDIFileBuilder.Track()
        high.addNote(pitch: 72, startTick: 0, durationTicks: 100)
        var low = MIDIFileBuilder.Track()
        low.addNote(pitch: 48, startTick: 0, durationTicks: 100)

        let song = try MIDIParser.parse(data: MIDIFileBuilder(tracks: [high, low]).build())

        XCTAssertEqual(song.notes.first { $0.pitch == 72 }?.hand, .right)
        XCTAssertEqual(song.notes.first { $0.pitch == 48 }?.hand, .left)
    }

    func testSingleTrackSplitsAroundMiddleC() throws {
        let song = try parse(header() + track([
            0x00, 0x90, 59, 80, 0x00, 60, 80, 0x00, 61, 80,
            0x60, 59, 0, 0x00, 60, 0, 0x00, 61, 0,
        ]))
        let hands = Dictionary(uniqueKeysWithValues: song.notes.map { ($0.pitch, $0.hand) })

        XCTAssertEqual(hands[59], .left)
        XCTAssertEqual(hands[60], .right)
        XCTAssertEqual(hands[61], .right)
    }

    func testFormat1WithOneNoteTrackSplitsAroundMiddleC() throws {
        var conductor = MIDIFileBuilder.Track()
        conductor.addTempo(beatsPerMinute: 120)
        var notes = MIDIFileBuilder.Track()
        notes.addNote(pitch: 48, startTick: 0, durationTicks: 100)
        notes.addNote(pitch: 72, startTick: 0, durationTicks: 100)

        let song = try MIDIParser.parse(data: MIDIFileBuilder(tracks: [conductor, notes]).build())

        XCTAssertEqual(song.notes.first { $0.pitch == 48 }?.hand, .left)
        XCTAssertEqual(song.notes.first { $0.pitch == 72 }?.hand, .right)
    }

    func testStepFiltersPitchesByHand() throws {
        var low = MIDIFileBuilder.Track()
        low.addNote(pitch: 48, startTick: 0, durationTicks: 100)
        var high = MIDIFileBuilder.Track()
        high.addNote(pitch: 72, startTick: 0, durationTicks: 100)
        let song = try MIDIParser.parse(data: MIDIFileBuilder(tracks: [low, high]).build())

        XCTAssertEqual(song.steps[0].pitches(for: .both), [48, 72])
        XCTAssertEqual(song.steps[0].pitches(for: .right), [72])
        XCTAssertEqual(song.steps[0].pitches(for: .left), [48])
    }

    // MARK: - Errors

    private func assertThrows(_ bytes: [UInt8], _ expected: MIDIParseError, line: UInt = #line) {
        XCTAssertThrowsError(try parse(bytes), line: line) {
            XCTAssertEqual($0 as? MIDIParseError, expected, line: line)
        }
    }

    func testEmptyDataThrows() {
        assertThrows([], .emptyData)
    }

    func testGarbageThrows() {
        assertThrows(Array("this is not a midi file".utf8), .notMIDIFile)
        assertThrows([0x4D, 0x54], .notMIDIFile)
    }

    func testTruncatedHeaderThrows() {
        assertThrows(Array("MThd".utf8) + [0, 0], .truncatedData)
        assertThrows(Array(header().prefix(10)), .truncatedData)
    }

    func testShortHeaderLengthThrows() {
        assertThrows(Array("MThd".utf8) + [0, 0, 0, 2, 0, 0], .invalidHeader)
    }

    func testFormat2IsUnsupported() {
        assertThrows(header(format: 2) + track([]), .unsupportedFormat(2))
    }

    func testNoTracksThrows() {
        assertThrows(header(tracks: 0), .noTracks)
        assertThrows(header(tracks: 1), .noTracks)
    }

    func testZeroDivisionThrows() {
        assertThrows(header(division: 0) + track([]), .invalidHeader)
    }

    func testTrackLengthBeyondFileThrows() {
        let bytes = header() + Array("MTrk".utf8) + [0, 0, 0xFF, 0xFF, 0x00]
        assertThrows(bytes, .truncatedData)
    }

    func testEventCutOffInsideTrackThrows() {
        assertThrows(header() + track([0x00, 0x90, 60], endOfTrack: false), .truncatedData)
        assertThrows(header() + track([0x00, 0xFF, 0x03, 0x20, 0x41], endOfTrack: false), .truncatedData)
    }

    func testInvalidStatusByteThrows() {
        assertThrows(header() + track([0x00, 0xF4]), .invalidStatusByte(0xF4))
    }

    func testFileWithoutNotesThrows() {
        assertThrows(header() + track(tempo120), .noPlayableNotes)
    }

    // MARK: - Built-in songs

    func testBuiltInSongsParse() throws {
        XCTAssertEqual(BuiltInSongs.all.count, 3)
        XCTAssertEqual(BuiltInSongs.all.first?.id, BuiltInSongs.odeToJoy.id)
        for builtIn in BuiltInSongs.sampleFiles {
            let song = try builtIn.parsed()
            XCTAssertEqual(song.title, builtIn.title)
            XCTAssertGreaterThan(song.steps.count, 10, builtIn.title)
            XCTAssertGreaterThan(song.durationSeconds, 5, builtIn.title)
            XCTAssertTrue(song.notes.contains { $0.hand == .left }, "\(builtIn.title) needs a left hand")
            XCTAssertTrue(song.notes.contains { $0.hand == .right }, "\(builtIn.title) needs a right hand")
        }
    }

    func testChordDrillChangesTempo() throws {
        let song = try BuiltInSongs.chordDrill.parsed()
        XCTAssertEqual(song.format, 1)
        XCTAssertEqual(song.tempoEvents.count, 2)
    }

    func testTwinkleIsFormat0() throws {
        XCTAssertEqual(try BuiltInSongs.twinkle.parsed().format, 0)
    }

    /// `samples/` holds the files uploaded to the bucket, so it must not drift from the source.
    func testCheckedInSamplesMatchGeneratedSongs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("samples")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path), "samples/ is not reachable from here")

        for sample in BuiltInSongs.sampleFiles {
            let data = try Data(contentsOf: directory.appendingPathComponent(sample.fileName))
            XCTAssertEqual(data, sample.midiData, "\(sample.fileName) is stale. Run: swift run pianowait-samples")
        }
    }
}
