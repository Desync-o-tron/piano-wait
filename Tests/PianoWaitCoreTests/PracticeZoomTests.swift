import XCTest
@testable import PianoWaitCore

final class PracticeZoomTests: XCTestCase {
    private let c4: UInt8 = 60
    private let accuracy = 1e-9

    // MARK: - Mapping

    func testFullViewMatchesTheLayout() {
        let viewport = PianoKeyboardViewport()
        for note in MIDINote.pianoRange {
            let expected = viewport.layout.frame(for: note)!
            let frame = viewport.frame(for: note)!
            XCTAssertEqual(frame.x, expected.x, accuracy: accuracy)
            XCTAssertEqual(frame.width, expected.width, accuracy: accuracy)
        }
        XCTAssertEqual(viewport.visibleNotes, MIDINote.pianoRange)
    }

    /// Practice opens fitted to the song, which must look the same as the old auto-zoomed keyboard.
    func testFittingMatchesTheAutoZoomedLayout() throws {
        for builtIn in BuiltInSongs.all {
            let fitted = PianoKeyboardLayout.autoZoomed(for: try builtIn.parsed())
            let viewport = PianoKeyboardViewport(fitting: fitted.range)
            for note in fitted.range {
                let expected = fitted.frame(for: note)!
                let frame = viewport.frame(for: note)!
                XCTAssertEqual(frame.x, expected.x, accuracy: accuracy, "\(builtIn.title) \(note)")
                XCTAssertEqual(frame.width, expected.width, accuracy: accuracy, "\(builtIn.title) \(note)")
            }
        }
    }

    func testFittingWidensToWhiteKeys() {
        // C#4 to F#5 starts and ends on black keys.
        let viewport = PianoKeyboardViewport(fitting: 61...78)
        XCTAssertTrue(viewport.visibleNotes.contains(60))
        XCTAssertTrue(viewport.visibleNotes.contains(79))
        XCTAssertEqual(viewport.frame(for: 60)?.x ?? 1, 0, accuracy: accuracy)
        let high = viewport.frame(for: 79)!
        XCTAssertEqual(high.x + high.width, 1, accuracy: accuracy)
    }

    func testKeysOffScreenHaveNoFrame() {
        let viewport = PianoKeyboardViewport(fitting: 60...84)
        XCTAssertNil(viewport.frame(for: 21))
        XCTAssertNil(viewport.frame(for: 108))
        XCTAssertNotNil(viewport.frame(for: 72))
    }

    func testKeysPartlyOnScreenKeepTheirFrame() throws {
        let layout = PianoKeyboardLayout()
        let key = try XCTUnwrap(layout.frame(for: c4))
        let viewport = PianoKeyboardViewport(layout: layout, start: key.x + key.width / 2, width: 0.5)

        let frame = try XCTUnwrap(viewport.frame(for: c4))
        XCTAssertLessThan(frame.x, 0)
        XCTAssertGreaterThan(frame.x + frame.width, 0)
    }

    func testHitTestingRoundTripsWhenZoomedAndPanned() throws {
        let viewport = PianoKeyboardViewport(fitting: 48...72).zoomed(by: 1.3, anchor: 0.2).panned(by: 0.15)
        for note in viewport.visibleNotes {
            let frame = try XCTUnwrap(viewport.frame(for: note))
            let hit = viewport.note(atX: frame.x + frame.width / 2, y: MIDINote.isBlackKey(note) ? 0.3 : 0.9)
            XCTAssertEqual(hit, note, MIDINote.name(note))
        }
        XCTAssertNil(viewport.note(atX: -0.01, y: 0.9))
        XCTAssertNil(viewport.note(atX: 1, y: 0.9))
    }

    // MARK: - Zooming

    func testZoomHoldsTheAnchorStill() throws {
        let viewport = PianoKeyboardViewport(fitting: 40...90)
        for anchor in [0.0, 0.25, 0.5, 0.8, 1.0] {
            let zoomed = viewport.zoomed(by: 1.5, anchor: anchor)
            XCTAssertEqual(zoomed.width, viewport.width / 1.5, accuracy: accuracy)
            XCTAssertEqual(
                zoomed.start + anchor * zoomed.width,
                viewport.start + anchor * viewport.width,
                accuracy: accuracy
            )
        }
    }

    func testZoomInThenOutReturns() {
        let viewport = PianoKeyboardViewport(fitting: 40...90)
        let result = viewport.zoomed(by: 1.7, anchor: 0.3).zoomed(by: 1 / 1.7, anchor: 0.3)
        XCTAssertTrue(result.isApproximatelyEqual(to: viewport))
    }

    func testSmallStepsCompoundLikeOneBigStep() {
        let viewport = PianoKeyboardViewport(fitting: 40...90)
        var stepped = viewport
        for _ in 0..<20 {
            stepped = stepped.zoomed(by: pow(2, 1.0 / 20), anchor: 0.4)
        }
        XCTAssertTrue(stepped.isApproximatelyEqual(to: viewport.zoomed(by: 2, anchor: 0.4)))
    }

    func testZoomInStopsAtOneOctave() {
        var viewport = PianoKeyboardViewport()
        XCTAssertTrue(viewport.canZoomIn)
        for _ in 0..<40 { viewport = viewport.zoomed(by: 1.5) }

        XCTAssertFalse(viewport.canZoomIn)
        XCTAssertEqual(viewport.width * 52, PianoKeyboardViewport.minimumVisibleWhiteKeys, accuracy: accuracy)
    }

    func testZoomOutStopsAtTheWholeKeyboard() {
        var viewport = PianoKeyboardViewport(fitting: 60...84)
        XCTAssertTrue(viewport.canZoomOut)
        for _ in 0..<40 { viewport = viewport.zoomed(by: 0.5, anchor: 0.9) }

        XCTAssertFalse(viewport.canZoomOut)
        XCTAssertEqual(viewport.start, 0)
        XCTAssertEqual(viewport.width, 1)
        XCTAssertEqual(viewport.visibleNotes.count, 88)
    }

    func testZoomingOutNearAnEdgeStaysOnTheKeyboard() {
        let viewport = PianoKeyboardViewport(start: 0.85, width: 0.15).zoomed(by: 0.5, anchor: 1)
        XCTAssertEqual(viewport.width, 0.3, accuracy: accuracy)
        XCTAssertEqual(viewport.start + viewport.width, 1, accuracy: accuracy)
    }

    func testInvalidZoomFactorsAreIgnored() {
        let viewport = PianoKeyboardViewport(fitting: 40...90)
        for factor in [0, -1, Double.infinity, Double.nan] {
            XCTAssertEqual(viewport.zoomed(by: factor), viewport)
        }
    }

    func testShortKeyboardsCannotZoomPastTheirSize() {
        let layout = PianoKeyboardLayout(range: 60...64)
        let viewport = PianoKeyboardViewport(layout: layout).zoomed(by: 4)
        XCTAssertEqual(viewport.width, 1)
        XCTAssertFalse(viewport.canZoomIn)
    }

    // MARK: - Panning

    func testPanMovesByAFractionOfTheView() {
        let viewport = PianoKeyboardViewport(start: 0.3, width: 0.2)
        XCTAssertEqual(viewport.panned(by: 0.5).start, 0.4, accuracy: accuracy)
        XCTAssertEqual(viewport.panned(by: -0.5).start, 0.2, accuracy: accuracy)
        XCTAssertEqual(viewport.panned(by: 0.5).width, 0.2, accuracy: accuracy)
    }

    func testPanStopsAtTheEnds() {
        let viewport = PianoKeyboardViewport(start: 0.3, width: 0.2)

        let left = viewport.panned(by: -100)
        XCTAssertEqual(left.start, 0)
        XCTAssertFalse(left.canPanLeft)
        XCTAssertTrue(left.canPanRight)

        let right = viewport.panned(by: 100)
        XCTAssertEqual(right.start + right.width, 1, accuracy: accuracy)
        XCTAssertFalse(right.canPanRight)
        XCTAssertTrue(right.canPanLeft)
    }

    func testTheWholeKeyboardCannotPan() {
        let viewport = PianoKeyboardViewport()
        XCTAssertFalse(viewport.canPanLeft)
        XCTAssertFalse(viewport.canPanRight)
        XCTAssertEqual(viewport.panned(by: 0.5), viewport)
    }

    func testPanningMovesTheKeysTheOtherWayOnScreen() throws {
        let viewport = PianoKeyboardViewport(start: 0.3, width: 0.3)
        let before = try XCTUnwrap(viewport.frame(for: c4))
        let after = try XCTUnwrap(viewport.panned(by: 0.1).frame(for: c4))
        XCTAssertEqual(after.x, before.x - 0.1, accuracy: accuracy)
    }

    // MARK: - Practice zoom

    private func makeZoom() throws -> PracticeZoom {
        PracticeZoom(song: try BuiltInSongs.odeToJoy.parsed())
    }

    func testPracticeStartsFittedToTheSong() throws {
        let song = try BuiltInSongs.odeToJoy.parsed()
        let zoom = PracticeZoom(song: song)

        XCTAssertTrue(zoom.isFittedToSong)
        XCTAssertFalse(zoom.showsAllKeys)
        XCTAssertEqual(zoom.lookaheadSeconds, 4)
        for note in song.notes {
            XCTAssertNotNil(zoom.keyboard.frame(for: note.pitch))
        }
    }

    func testButtonsStepAndReturnToPresets() throws {
        var zoom = try makeZoom()
        let fitted = zoom.keyboard

        zoom.zoomIn()
        XCTAssertLessThan(zoom.keyboard.width, fitted.width)
        XCTAssertFalse(zoom.isFittedToSong)
        zoom.zoomOut()
        XCTAssertTrue(zoom.isFittedToSong)

        zoom.showAllKeys()
        XCTAssertTrue(zoom.showsAllKeys)
        XCTAssertEqual(zoom.keyboard.visibleNotes.count, 88)
        zoom.fitSong()
        XCTAssertEqual(zoom.keyboard, fitted)
    }

    func testPanButtonsMoveBothWays() throws {
        var zoom = try makeZoom()
        let start = zoom.keyboard.start

        zoom.panRight()
        XCTAssertGreaterThan(zoom.keyboard.start, start)
        zoom.panLeft()
        XCTAssertEqual(zoom.keyboard.start, start, accuracy: accuracy)
    }

    func testLookaheadStaysInRange() throws {
        var zoom = try makeZoom()

        zoom.lookaheadSeconds = 6
        XCTAssertEqual(zoom.lookaheadSeconds, 6)
        zoom.lookaheadSeconds = 1
        XCTAssertEqual(zoom.lookaheadSeconds, 2)
        zoom.lookaheadSeconds = 30
        XCTAssertEqual(zoom.lookaheadSeconds, 8)
    }

    func testFallPositionFollowsTheLookahead() throws {
        var zoom = try makeZoom()

        XCTAssertEqual(zoom.fallPosition(forTime: 10, playhead: 10), 0, accuracy: accuracy)
        XCTAssertEqual(zoom.fallPosition(forTime: 14, playhead: 10), 1, accuracy: accuracy)
        XCTAssertEqual(zoom.fallPosition(forTime: 12, playhead: 10), 0.5, accuracy: accuracy)

        zoom.lookaheadSeconds = 8
        XCTAssertEqual(zoom.fallPosition(forTime: 12, playhead: 10), 0.25, accuracy: accuracy)
        zoom.lookaheadSeconds = 2
        XCTAssertEqual(zoom.fallPosition(forTime: 12, playhead: 10), 1, accuracy: accuracy)
    }
}
