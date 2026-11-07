import Foundation

/// Branding and runtime configuration read from the app's `Info.plist`.
public struct AppConfiguration: Sendable, Equatable {
    public static let defaultDisplayName = "Free MIDI Player"
    public static let fossDisplayName = "PianoWait"
    public static let defaultBundleIdentifier = "com.lukeknoble.freemidiplayer"

    public let displayName: String
    public let bundleIdentifier: String
    public let version: String
    public let buildNumber: String

    public init(
        displayName: String = Self.defaultDisplayName,
        bundleIdentifier: String = Self.defaultBundleIdentifier,
        version: String = "1.0",
        buildNumber: String = "1"
    ) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildNumber = buildNumber
    }

    public init(infoDictionary: [String: Any]?) {
        let rawDisplayName = (infoDictionary?["CFBundleDisplayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBundleName = (infoDictionary?["CFBundleName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let rawDisplayName, !rawDisplayName.isEmpty, !rawDisplayName.hasPrefix("$(") {
            resolvedName = rawDisplayName
        } else if let rawBundleName, !rawBundleName.isEmpty, !rawBundleName.hasPrefix("$(") {
            resolvedName = rawBundleName
        } else {
            resolvedName = Self.defaultDisplayName
        }

        let rawBundleID = (infoDictionary?["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleID: String
        if let rawBundleID, !rawBundleID.isEmpty, !rawBundleID.hasPrefix("$(") {
            resolvedBundleID = rawBundleID
        } else {
            resolvedBundleID = Self.defaultBundleIdentifier
        }

        let rawVersion = (infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVersion = (rawVersion?.isEmpty == false && rawVersion?.hasPrefix("$(") == false)
            ? rawVersion!
            : "1.0"

        let rawBuild = (infoDictionary?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBuild = (rawBuild?.isEmpty == false && rawBuild?.hasPrefix("$(") == false)
            ? rawBuild!
            : "1"

        self.init(
            displayName: resolvedName,
            bundleIdentifier: resolvedBundleID,
            version: resolvedVersion,
            buildNumber: resolvedBuild
        )
    }

    public static var current: AppConfiguration {
        AppConfiguration(infoDictionary: Bundle.main.infoDictionary)
    }
}

/// Google AdMob / Mobile Ads configuration loaded from `Info.plist` with safe Google test IDs as defaults.
public struct AdConfiguration: Sendable, Equatable {
    /// Official Google Mobile Ads iOS sample App ID and test Ad Unit IDs.
    /// Swap these in `App/Info.plist` (or via Xcode build settings) with production AdMob IDs before release.
    public static let testApplicationID = "ca-app-pub-3940256099942544~1458002511"
    public static let testBannerAdUnitID = "ca-app-pub-3940256099942544/2435281174"
    public static let testInterstitialAdUnitID = "ca-app-pub-3940256099942544/4411468910"
    public static let googleTestPublisherPrefix = "ca-app-pub-3940256099942544"

    public static let applicationIDKey = "GADApplicationIdentifier"
    public static let bannerAdUnitIDKey = "AdMobBannerAdUnitID"
    public static let interstitialAdUnitIDKey = "AdMobInterstitialAdUnitID"
    public static let adsEnabledKey = "AdsEnabled"

    public let applicationID: String
    public let bannerAdUnitID: String
    public let interstitialAdUnitID: String
    public let isEnabled: Bool

    public init(
        applicationID: String = Self.testApplicationID,
        bannerAdUnitID: String = Self.testBannerAdUnitID,
        interstitialAdUnitID: String = Self.testInterstitialAdUnitID,
        isEnabled: Bool = true
    ) {
        self.applicationID = applicationID
        self.bannerAdUnitID = bannerAdUnitID
        self.interstitialAdUnitID = interstitialAdUnitID
        self.isEnabled = isEnabled
    }

    public init(infoDictionary: [String: Any]?, arguments: [String] = ProcessInfo.processInfo.arguments) {
        let appID = Self.nonEmptyValue(forKey: Self.applicationIDKey, in: infoDictionary)
            ?? Self.testApplicationID
        let bannerID = Self.nonEmptyValue(forKey: Self.bannerAdUnitIDKey, in: infoDictionary)
            ?? Self.testBannerAdUnitID
        let interstitialID = Self.nonEmptyValue(forKey: Self.interstitialAdUnitIDKey, in: infoDictionary)
            ?? Self.testInterstitialAdUnitID

        let plistEnabled: Bool
        if let flag = infoDictionary?[Self.adsEnabledKey] as? Bool {
            plistEnabled = flag
        } else if let str = infoDictionary?[Self.adsEnabledKey] as? String {
            plistEnabled = (str as NSString).boolValue
        } else {
            plistEnabled = true
        }

        let disabledByLaunchArg = arguments.contains("--disable-ads")
        self.init(
            applicationID: appID,
            bannerAdUnitID: bannerID,
            interstitialAdUnitID: interstitialID,
            isEnabled: plistEnabled && !disabledByLaunchArg
        )
    }

    public static var current: AdConfiguration {
        AdConfiguration(infoDictionary: Bundle.main.infoDictionary)
    }

    /// True when either the App ID or any Ad Unit ID is still using Google's public sample publisher prefix.
    public var isUsingTestAdUnits: Bool {
        applicationID.hasPrefix(Self.googleTestPublisherPrefix)
            || bannerAdUnitID.hasPrefix(Self.googleTestPublisherPrefix)
            || interstitialAdUnitID.hasPrefix(Self.googleTestPublisherPrefix)
    }

    private static func nonEmptyValue(forKey key: String, in dict: [String: Any]?) -> String? {
        guard let raw = dict?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

/// Enforces that ads never block or interrupt active piano gameplay.
public enum AdPlacementPolicy: Sendable {
    /// Active piano gameplay includes both continuous playback and wait-for-note states.
    public static func isGameplayActive(in state: PlaybackState) -> Bool {
        switch state {
        case .playing, .waiting:
            return true
        case .paused, .finished:
            return false
        }
    }

    /// Within the practice screen, ads are only allowed on the post-song completion summary.
    public static func allowsAdInPracticeView(for state: PlaybackState) -> Bool {
        state == .finished
    }

    /// Determines whether a post-song interstitial may be presented.
    /// Never presents during active gameplay (`playing` or `waiting`) or while `paused` mid-song.
    public static func allowsPostSongInterstitial(
        for state: PlaybackState,
        adsEnabled: Bool = true,
        completedSongsSinceLastAd: Int,
        minimumSongsBetweenInterstitials: Int = 1,
        secondsSinceLastInterstitial: TimeInterval? = nil,
        minimumCooldownSeconds: TimeInterval = 90
    ) -> Bool {
        guard adsEnabled else { return false }
        guard state == .finished else { return false }
        guard completedSongsSinceLastAd >= max(1, minimumSongsBetweenInterstitials) else { return false }
        if let elapsed = secondsSinceLastInterstitial, elapsed < minimumCooldownSeconds {
            return false
        }
        return true
    }
}
