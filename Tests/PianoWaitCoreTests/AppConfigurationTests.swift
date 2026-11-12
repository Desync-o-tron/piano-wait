import XCTest
@testable import PianoWaitCore

final class AppConfigurationTests: XCTestCase {
    func testDefaultDisplayNameIsFreeMIDIPlayer() {
        let config = AppConfiguration(infoDictionary: nil)
        XCTAssertEqual(config.displayName, "free MIDI player (FOSS)")
        XCTAssertEqual(config.bundleIdentifier, "com.lukeknoble.freemidiplayer.ios")
    }

    func testReadsRebrandedInfoPlistValues() {
        let plist: [String: Any] = [
            "CFBundleDisplayName": "free MIDI player (FOSS)",
            "CFBundleIdentifier": "com.lukeknoble.freemidiplayer.ios",
            "CFBundleShortVersionString": "1.1.0",
            "CFBundleVersion": "42",
        ]
        let config = AppConfiguration(infoDictionary: plist)
        XCTAssertEqual(config.displayName, "free MIDI player (FOSS)")
        XCTAssertEqual(config.bundleIdentifier, "com.lukeknoble.freemidiplayer.ios")
        XCTAssertEqual(config.version, "1.1.0")
        XCTAssertEqual(config.buildNumber, "42")
    }

    func testUnexpandedBuildSettingPlaceholdersFallBackCleanly() {
        let plist: [String: Any] = [
            "CFBundleDisplayName": "$(APP_DISPLAY_NAME)",
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        ]
        let config = AppConfiguration(infoDictionary: plist)
        XCTAssertEqual(config.displayName, "free MIDI player (FOSS)")
        XCTAssertEqual(config.bundleIdentifier, "com.lukeknoble.freemidiplayer.ios")
        XCTAssertEqual(config.version, "1.0")
        XCTAssertEqual(config.buildNumber, "1")
    }

    func testAdConfigurationDefaultsToGoogleTestIDs() {
        let adConfig = AdConfiguration(infoDictionary: nil, arguments: [])
        XCTAssertEqual(adConfig.applicationID, AdConfiguration.testApplicationID)
        XCTAssertEqual(adConfig.bannerAdUnitID, AdConfiguration.testBannerAdUnitID)
        XCTAssertEqual(adConfig.interstitialAdUnitID, AdConfiguration.testInterstitialAdUnitID)
        XCTAssertTrue(adConfig.isEnabled)
        XCTAssertTrue(adConfig.isUsingTestAdUnits)
    }

    func testAdConfigurationSwapsInProductionAdMobIDsFromInfoPlist() {
        let plist: [String: Any] = [
            "GADApplicationIdentifier": "ca-app-pub-1234567890123456~9876543210",
            "AdMobBannerAdUnitID": "ca-app-pub-1234567890123456/1111111111",
            "AdMobInterstitialAdUnitID": "ca-app-pub-1234567890123456/2222222222",
            "AdsEnabled": true,
        ]
        let adConfig = AdConfiguration(infoDictionary: plist, arguments: [])
        XCTAssertEqual(adConfig.applicationID, "ca-app-pub-1234567890123456~9876543210")
        XCTAssertEqual(adConfig.bannerAdUnitID, "ca-app-pub-1234567890123456/1111111111")
        XCTAssertEqual(adConfig.interstitialAdUnitID, "ca-app-pub-1234567890123456/2222222222")
        XCTAssertTrue(adConfig.isEnabled)
        XCTAssertFalse(adConfig.isUsingTestAdUnits)
    }

    func testDisableAdsLaunchArgumentOverridesPlist() {
        let plist: [String: Any] = ["AdsEnabled": true]
        let adConfig = AdConfiguration(infoDictionary: plist, arguments: ["--disable-ads"])
        XCTAssertFalse(adConfig.isEnabled)
    }

    func testAdPlacementPolicyNeverInterruptsActivePianoGameplay() {
        XCTAssertTrue(AdPlacementPolicy.isGameplayActive(in: .playing))
        XCTAssertTrue(AdPlacementPolicy.isGameplayActive(in: .waiting))
        XCTAssertFalse(AdPlacementPolicy.isGameplayActive(in: .paused))
        XCTAssertFalse(AdPlacementPolicy.isGameplayActive(in: .finished))

        XCTAssertFalse(AdPlacementPolicy.allowsAdInPracticeView(for: .playing))
        XCTAssertFalse(AdPlacementPolicy.allowsAdInPracticeView(for: .waiting))
        XCTAssertFalse(AdPlacementPolicy.allowsAdInPracticeView(for: .paused))
        XCTAssertTrue(AdPlacementPolicy.allowsAdInPracticeView(for: .finished))

        for activeState in [PlaybackState.playing, .waiting, .paused] {
            XCTAssertFalse(
                AdPlacementPolicy.allowsPostSongInterstitial(
                    for: activeState,
                    completedSongsSinceLastAd: 5
                )
            )
        }

        XCTAssertTrue(
            AdPlacementPolicy.allowsPostSongInterstitial(
                for: .finished,
                completedSongsSinceLastAd: 1
            )
        )
        XCTAssertFalse(
            AdPlacementPolicy.allowsPostSongInterstitial(
                for: .finished,
                completedSongsSinceLastAd: 1,
                secondsSinceLastInterstitial: 30,
                minimumCooldownSeconds: 90
            )
        )
        XCTAssertTrue(
            AdPlacementPolicy.allowsPostSongInterstitial(
                for: .finished,
                completedSongsSinceLastAd: 1,
                secondsSinceLastInterstitial: 120,
                minimumCooldownSeconds: 90
            )
        )
    }

    func testOTAConfigurationAppliesOverridesAndLeavesUnspecifiedDefaultsIntact() throws {
        let json = Data("""
        {
          "version": 2,
          "updatedAt": "2026-11-07T15:00:00Z",
          "dsp": {
            "noiseGateRMS": 0.0018,
            "unexplainedShare": 0.22,
            "highOvertoneFundamentalMargin": 1.85
          },
          "engine": {
            "earlyGrace": 0.55,
            "partialChordGraceSeconds": 0.75,
            "highlightLeadTimeSeconds": 2.0
          },
          "ui": {
            "autoPanKeyboardToExpectedNotes": true,
            "showUpcomingStepHighlight": true
          }
        }
        """.utf8)

        let ota = try JSONDecoder().decode(OTAConfiguration.self, from: json)
        XCTAssertEqual(ota.version, 2)

        var dspConfig = AcousticPitchDetector.Configuration()
        ota.dsp?.apply(to: &dspConfig)
        XCTAssertEqual(dspConfig.noiseGateRMS, 0.0018, accuracy: 1e-6)
        XCTAssertEqual(dspConfig.unexplainedShare, 0.22, accuracy: 1e-6)
        XCTAssertEqual(dspConfig.highOvertoneFundamentalMargin, 1.85, accuracy: 1e-6)
        XCTAssertEqual(dspConfig.requiredConsecutiveFrames, 2, "Unspecified fields retain defaults")

        var engineConfig = WaitModeEngine.Configuration()
        ota.engine?.apply(to: &engineConfig)
        XCTAssertEqual(engineConfig.earlyGrace, 0.55, accuracy: 1e-6)
        XCTAssertEqual(engineConfig.partialChordGraceSeconds ?? 0, 0.75, accuracy: 1e-6)
        XCTAssertEqual(engineConfig.highlightLeadTimeSeconds, 2.0, accuracy: 1e-6)
    }

    func testRemoteConfigLoaderFetchesAndCachesOTAConfig() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteConfigLoaderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let body = Data("""
        {
          "version": 3,
          "dsp": { "noiseGateRMS": 0.0021 },
          "engine": { "highlightLeadTimeSeconds": 1.8 }
        }
        """.utf8)
        MockURLProtocol.install { _ in (200, body) }

        let loader = RemoteConfigLoader(
            bucket: "luke-piano-midis",
            cacheDirectory: tempDir,
            session: MockURLProtocol.makeSession()
        )
        let fetched = await loader.refresh()
        XCTAssertEqual(fetched.version, 3)
        XCTAssertEqual(fetched.dsp?.noiseGateRMS ?? 0, 0.0021, accuracy: 1e-6)
        XCTAssertEqual(fetched.engine?.highlightLeadTimeSeconds ?? 0, 1.8, accuracy: 1e-6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loader.cacheFileURL.path))
    }

    func testMonoWAVEncodingProducesValidRIFFHeader() {
        let samples = (0..<44_100).map { i in Float(sin(Double(i) * 2.0 * .pi * 440.0 / 44_100.0)) }
        let wav = PracticeTelemetryLogger.encodeMonoWAV16kHz(samples: samples, sourceSampleRate: 44_100)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        // 1 second at 16 kHz 16-bit mono = 32,000 bytes PCM + 44-byte WAV header = 32,044 bytes
        XCTAssertEqual(wav.count, 32_044)
    }
}
