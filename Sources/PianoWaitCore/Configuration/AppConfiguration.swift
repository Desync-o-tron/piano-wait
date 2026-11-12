import Foundation

/// Branding and runtime configuration read from the app's `Info.plist`.
public struct AppConfiguration: Sendable, Equatable {
    public static let defaultDisplayName = "free MIDI player (FOSS)"
    public static let fossDisplayName = "PianoWait"
    public static let defaultBundleIdentifier = "com.lukeknoble.freemidiplayer.ios"

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

/// Live over-the-air (OTA) configuration fetched from `gs://<bucket>/config/ota-config.json`.
///
/// Every field is optional so a remote JSON payload only needs to specify the parameters it
/// wants to override; unspecified fields fall back to the compiled defaults.
public struct OTAConfiguration: Codable, Sendable, Equatable {
    public struct DSP: Codable, Sendable, Equatable {
        public var noiseGateRMS: Float?
        public var requiredConsecutiveFrames: Int?
        public var onsetRiseRatio: Float?
        public var onsetFallRatio: Float?
        public var referenceA4: Double?
        public var tracksLiveTuning: Bool?
        public var fundamentalRatio: Float?
        public var supportRatio: Float?
        public var minimumSalience: Float?
        public var unexplainedShare: Float?
        public var highOvertoneFundamentalMargin: Float?
        public var requiredUnexplainedPartials: Int?

        public init(
            noiseGateRMS: Float? = nil,
            requiredConsecutiveFrames: Int? = nil,
            onsetRiseRatio: Float? = nil,
            onsetFallRatio: Float? = nil,
            referenceA4: Double? = nil,
            tracksLiveTuning: Bool? = nil,
            fundamentalRatio: Float? = nil,
            supportRatio: Float? = nil,
            minimumSalience: Float? = nil,
            unexplainedShare: Float? = nil,
            highOvertoneFundamentalMargin: Float? = nil,
            requiredUnexplainedPartials: Int? = nil
        ) {
            self.noiseGateRMS = noiseGateRMS
            self.requiredConsecutiveFrames = requiredConsecutiveFrames
            self.onsetRiseRatio = onsetRiseRatio
            self.onsetFallRatio = onsetFallRatio
            self.referenceA4 = referenceA4
            self.tracksLiveTuning = tracksLiveTuning
            self.fundamentalRatio = fundamentalRatio
            self.supportRatio = supportRatio
            self.minimumSalience = minimumSalience
            self.unexplainedShare = unexplainedShare
            self.highOvertoneFundamentalMargin = highOvertoneFundamentalMargin
            self.requiredUnexplainedPartials = requiredUnexplainedPartials
        }

        public func apply(to config: inout AcousticPitchDetector.Configuration) {
            if let v = noiseGateRMS { config.noiseGateRMS = v }
            if let v = requiredConsecutiveFrames { config.requiredConsecutiveFrames = v }
            if let v = onsetRiseRatio { config.onsetRiseRatio = v }
            if let v = onsetFallRatio { config.onsetFallRatio = v }
            if let v = referenceA4 { config.referenceA4 = v }
            if let v = tracksLiveTuning { config.tracksLiveTuning = v }
            if let v = fundamentalRatio { config.fundamentalRatio = v }
            if let v = supportRatio { config.supportRatio = v }
            if let v = minimumSalience { config.minimumSalience = v }
            if let v = unexplainedShare { config.unexplainedShare = v }
            if let v = highOvertoneFundamentalMargin { config.highOvertoneFundamentalMargin = v }
            if let v = requiredUnexplainedPartials { config.requiredUnexplainedPartials = v }
        }
    }

    public struct Engine: Codable, Sendable, Equatable {
        public var rollWindow: TimeInterval?
        public var earlyGrace: TimeInterval?
        public var strikeMemorySeconds: TimeInterval?
        public var continuousWindow: TimeInterval?
        public var synthEchoSuppression: TimeInterval?
        public var partialChordGraceSeconds: TimeInterval?
        public var highlightLeadTimeSeconds: TimeInterval?

        public init(
            rollWindow: TimeInterval? = nil,
            earlyGrace: TimeInterval? = nil,
            strikeMemorySeconds: TimeInterval? = nil,
            continuousWindow: TimeInterval? = nil,
            synthEchoSuppression: TimeInterval? = nil,
            partialChordGraceSeconds: TimeInterval? = nil,
            highlightLeadTimeSeconds: TimeInterval? = nil
        ) {
            self.rollWindow = rollWindow
            self.earlyGrace = earlyGrace
            self.strikeMemorySeconds = strikeMemorySeconds
            self.continuousWindow = continuousWindow
            self.synthEchoSuppression = synthEchoSuppression
            self.partialChordGraceSeconds = partialChordGraceSeconds
            self.highlightLeadTimeSeconds = highlightLeadTimeSeconds
        }

        public func apply(to config: inout WaitModeEngine.Configuration) {
            if let v = rollWindow { config.rollWindow = v }
            if let v = earlyGrace { config.earlyGrace = v }
            if let v = strikeMemorySeconds { config.strikeMemorySeconds = v }
            if let v = continuousWindow { config.continuousWindow = v }
            if let v = synthEchoSuppression { config.synthEchoSuppression = v }
            if let v = partialChordGraceSeconds { config.partialChordGraceSeconds = v }
            if let v = highlightLeadTimeSeconds { config.highlightLeadTimeSeconds = v }
        }
    }

    public struct UI: Codable, Sendable, Equatable {
        public var autoPanKeyboardToExpectedNotes: Bool?
        public var showUpcomingStepHighlight: Bool?

        public init(
            autoPanKeyboardToExpectedNotes: Bool? = nil,
            showUpcomingStepHighlight: Bool? = nil
        ) {
            self.autoPanKeyboardToExpectedNotes = autoPanKeyboardToExpectedNotes
            self.showUpcomingStepHighlight = showUpcomingStepHighlight
        }
    }

    public struct Telemetry: Codable, Sendable, Equatable {
        public var enabled: Bool?
        public var flushStepInterval: Int?
        public var uploadAudioSnippets: Bool?
        public var telemetryBucket: String?

        public init(
            enabled: Bool? = nil,
            flushStepInterval: Int? = nil,
            uploadAudioSnippets: Bool? = nil,
            telemetryBucket: String? = nil
        ) {
            self.enabled = enabled
            self.flushStepInterval = flushStepInterval
            self.uploadAudioSnippets = uploadAudioSnippets
            self.telemetryBucket = telemetryBucket
        }
    }

    public static let defaultRemoteObjectPath = "config/ota-config.json"

    public var version: Int
    public var updatedAt: String?
    public var dsp: DSP?
    public var engine: Engine?
    public var ui: UI?
    public var telemetry: Telemetry?

    public init(
        version: Int = 1,
        updatedAt: String? = nil,
        dsp: DSP? = nil,
        engine: Engine? = nil,
        ui: UI? = nil,
        telemetry: Telemetry? = nil
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.dsp = dsp
        self.engine = engine
        self.ui = ui
        self.telemetry = telemetry
    }
}

/// Fetches and caches `OTAConfiguration` from the Google Cloud Storage bucket so DSP, engine,
/// and UI parameters can be tuned over the air without waiting for App Store / Play Store review.
public actor RemoteConfigLoader {
    public static let shared = RemoteConfigLoader()

    public nonisolated let bucket: String
    public nonisolated let objectPath: String
    public nonisolated let cacheFileURL: URL
    private let session: URLSession
    private var cachedConfig: OTAConfiguration?

    public init(
        bucket: String = CloudBucketClient.defaultBucket,
        objectPath: String = OTAConfiguration.defaultRemoteObjectPath,
        cacheDirectory: URL = URL.documentsDirectory.appendingPathComponent("Config", isDirectory: true),
        session: URLSession = .shared
    ) {
        self.bucket = bucket
        self.objectPath = objectPath
        self.cacheFileURL = cacheDirectory.appendingPathComponent("ota-config.json", isDirectory: false)
        self.session = session
        if let data = try? Data(contentsOf: cacheFileURL),
           let decoded = try? JSONDecoder().decode(OTAConfiguration.self, from: data) {
            self.cachedConfig = decoded
        }
    }

    public var remoteURL: URL? {
        let trimmed = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "https://storage.googleapis.com/\(trimmed)/\(objectPath)")
    }

    public func currentConfiguration() -> OTAConfiguration {
        cachedConfig ?? OTAConfiguration()
    }

    @discardableResult
    public func refresh() async -> OTAConfiguration {
        guard let url = remoteURL else {
            return currentConfiguration()
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return currentConfiguration()
            }
            let decoded = try JSONDecoder().decode(OTAConfiguration.self, from: data)
            cachedConfig = decoded
            let dir = cacheFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: cacheFileURL, options: .atomic)
            return decoded
        } catch {
            return currentConfiguration()
        }
    }
}
