import XCTest

/// Drives the real app in the simulator: launch, the library, and the practice screen.
final class PianoWaitUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp(arguments: [String] = ["--uitesting"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openOdeToJoy(in app: XCUIApplication) {
        let song = app.buttons["song-Ode to Joy"]
        XCTAssertTrue(song.waitForExistence(timeout: 15))
        song.tap()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLibraryListsBuiltInSongsOutOfTheBox() {
        let app = launchApp()

        XCTAssertTrue(app.navigationBars["free MIDI player (FOSS)"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["adBannerView"].waitForExistence(timeout: 10))

        for title in ["Dark Is the Night", "Ode to Joy", "Minuet in G", "Für Elise (Opening)"] {
            XCTAssertTrue(app.buttons["song-\(title)"].waitForExistence(timeout: 15), title)
        }
        attachScreenshot("Library")

        // Active practice must never show the ad banner while playing or waiting.
        openOdeToJoy(in: app)
        XCTAssertFalse(app.otherElements["adBannerView"].exists)
    }

    /// The keys and how far ahead the screen shows, which the zoom button reports as its value.
    @MainActor
    private func zoomSummary(in app: XCUIApplication) -> String {
        app.buttons["zoom"].value as? String ?? ""
    }

    private func keyCount(in summary: String) -> Int {
        Int(summary.prefix { $0.isNumber }) ?? 0
    }

    @MainActor
    func testZoomPopoverChangesKeysAndLookahead() {
        let app = launchApp()
        openOdeToJoy(in: app)

        app.buttons["zoom"].tap()
        let keys = app.staticTexts["zoomKeys"]
        XCTAssertTrue(keys.waitForExistence(timeout: 5))
        attachScreenshot("Zoom popover")
        let fitted = keys.label

        app.buttons["zoom88Keys"].tap()
        XCTAssertEqual(keys.label, "88 keys")
        XCTAssertFalse(app.buttons["zoomOut"].isEnabled)
        XCTAssertFalse(app.buttons["panLeft"].isEnabled)

        app.buttons["zoomFitSong"].tap()
        XCTAssertEqual(keys.label, fitted)

        app.buttons["zoomIn"].tap()
        XCTAssertLessThan(keyCount(in: keys.label), keyCount(in: fitted))
        app.buttons["zoomOut"].tap()
        XCTAssertEqual(keys.label, fitted)

        let lookahead = app.staticTexts["zoomLookahead"]
        XCTAssertEqual(lookahead.label, "4s ahead")
        app.sliders["zoomLookaheadSlider"].adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(lookahead.label, "8s ahead")
        app.sliders["zoomLookaheadSlider"].adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(lookahead.label, "2s ahead")
        attachScreenshot("Zoom popover at 2s")
    }

    @MainActor
    func testPinchingZoomsAndDraggingPans() {
        let app = launchApp()
        openOdeToJoy(in: app)
        let notes = app.otherElements["fallingNotes"]
        let keyboard = app.otherElements["pianoKeyboard"]
        XCTAssertTrue(notes.exists)
        let fitted = zoomSummary(in: app)

        // Spreading the fingers on the falling notes shows fewer keys.
        notes.pinch(withScale: 1.8, velocity: 2)
        let zoomedIn = zoomSummary(in: app)
        XCTAssertLessThan(keyCount(in: zoomedIn), keyCount(in: fitted), zoomedIn)
        attachScreenshot("Pinched in")

        // Dragging across the falling notes moves to other keys, without changing how many.
        notes.swipeRight(velocity: .slow)
        let panned = zoomSummary(in: app)
        XCTAssertNotEqual(panned, zoomedIn)
        attachScreenshot("Panned")

        // Pinching the keyboard zooms too, and its fingers play nothing that advances the song.
        keyboard.pinch(withScale: 0.5, velocity: -2)
        let zoomedOut = zoomSummary(in: app)
        XCTAssertGreaterThan(keyCount(in: zoomedOut), keyCount(in: panned), zoomedOut)
        attachScreenshot("Pinched out on the keyboard")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testPracticeWaitsAtTheFirstStepThenSkipAdvances() {
        let app = launchApp()
        openOdeToJoy(in: app)
        attachScreenshot("Practice before playing")

        app.buttons["playPause"].tap()

        let status = app.staticTexts["practiceStatus"]
        let isWaiting = NSPredicate(format: "label BEGINSWITH 'Play '")
        expectation(for: isWaiting, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        attachScreenshot("Waiting at the first step")

        let firstPrompt = status.label
        XCTAssertTrue(firstPrompt.contains("E4"), firstPrompt)
        XCTAssertTrue(firstPrompt.contains("C3"), firstPrompt)

        // It keeps waiting while nothing is played.
        sleep(2)
        XCTAssertEqual(status.label, firstPrompt)

        app.buttons["skipStep"].tap()
        expectation(for: NSPredicate(format: "label != %@", firstPrompt), evaluatedWith: status)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testTouchingAWrongKeyDoesNotAdvance() {
        let app = launchApp()
        openOdeToJoy(in: app)
        app.buttons["playPause"].tap()

        let status = app.staticTexts["practiceStatus"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Play '"), evaluatedWith: status)
        waitForExpectations(timeout: 10)

        let keyboard = app.otherElements["pianoKeyboard"]
        XCTAssertTrue(keyboard.exists)
        let prompt = status.label
        keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.9)).tap()
        sleep(1)
        XCTAssertEqual(status.label, prompt)
    }

    @MainActor
    func testControlsWorkInLandscape() {
        let app = launchApp()
        openOdeToJoy(in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["pianoKeyboard"].exists)
        attachScreenshot("Practice in landscape")

        app.buttons["playPause"].tap()
        let status = app.staticTexts["practiceStatus"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Play '"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testSpeedPopoverOffersPresets() {
        let app = launchApp()
        openOdeToJoy(in: app)

        app.buttons["speed"].tap()
        let preset = app.buttons["50%"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        attachScreenshot("Speed popover")
        preset.tap()
    }

    /// Syncs with the real bucket, then opens a downloaded song. The bucket's contents are not under
    /// this test's control, so an emptied bucket skips rather than fails.
    @MainActor
    func testSyncingTheBucketListsAndOpensCloudSongs() throws {
        let app = launchApp()
        let sync = app.buttons["syncBucket"]
        try XCTSkipUnless(sync.waitForExistence(timeout: 5), "No cloud bucket is configured.")
        sync.tap()

        let cloudSong = app.buttons["song-Twinkle Twinkle"]
        try XCTSkipUnless(cloudSong.waitForExistence(timeout: 30), "twinkle_twinkle.mid is not in the bucket")
        attachScreenshot("Library after sync")

        let isCached = NSPredicate(format: "label CONTAINS 'Cached'")
        expectation(for: isCached, evaluatedWith: cloudSong)
        waitForExpectations(timeout: 30)

        cloudSong.tap()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 15))
    }

    /// Runs the real audio path: session, synthesizer, and microphone, whatever the answer to the
    /// permission prompt. An engine or isolation mistake here crashes the app and fails the test.
    @MainActor
    func testPracticeWithRealAudioPathDoesNotCrash() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["--uitesting", "--uitesting-microphone"]
        app.launch()
        openOdeToJoy(in: app)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }

        app.buttons["playPause"].tap()
        sleep(4)

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["playPause"].exists)
        attachScreenshot("Practice with the microphone on")

        // Leaving tears down the audio path.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["song-Ode to Joy"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
