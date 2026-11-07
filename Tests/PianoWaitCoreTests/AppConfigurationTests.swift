import XCTest
@testable import PianoWaitCore

final class AppConfigurationTests: XCTestCase {
    func testDefaultDisplayNameIsFreeMIDIPlayer() {
        let config = AppConfiguration(infoDictionary: nil)
        XCTAssertEqual(config.displayName, "Free MIDI Player")
        XCTAssertEqual(config.bundleIdentifier, "com.lukeknoble.freemidiplayer")
    }

    func testReadsRebrandedInfoPlistValues() {
        let plist: [String: Any] = [
            "CFBundleDisplayName": "Free MIDI Player",
            "CFBundleIdentifier": "com.lukeknoble.freemidiplayer",
            "CFBundleShortVersionString": "1.1.0",
            "CFBundleVersion": "42",
        ]
        let config = AppConfiguration(infoDictionary: plist)
        XCTAssertEqual(config.displayName, "Free MIDI Player")
        XCTAssertEqual(config.bundleIdentifier, "com.lukeknoble.freemidiplayer")
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
        XCTAssertEqual(config.displayName, "Free MIDI Player")
        XCTAssertEqual(config.bundleIdentifier, "com.lukeknoble.freemidiplayer")
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
}
