import Foundation
import Observation
import PianoWaitCore
import UIKit
#if canImport(GoogleMobileAds)
@preconcurrency import GoogleMobileAds
#endif

/// Manages Google AdMob initialization and post-song interstitial ads while guaranteeing
/// that active piano practice (`playing` or `waiting`) is never interrupted.
@MainActor
@Observable
final class AdManager: NSObject {
    static let shared = AdManager()

    let configuration: AdConfiguration
    private(set) var isSDKInitialized = false
    private(set) var isInterstitialLoaded = false
    private(set) var completedSongsSinceLastInterstitial = 0
    private(set) var lastInterstitialPresentedAt: Date?
    private(set) var activeGameplayLockCount = 0

    #if canImport(GoogleMobileAds)
    private var interstitialAd: InterstitialAd?
    #endif

    init(configuration: AdConfiguration = .current) {
        self.configuration = configuration
        super.init()
    }

    var shouldShowAds: Bool {
        configuration.isEnabled
    }

    var isGameplayActive: Bool {
        activeGameplayLockCount > 0
    }

    /// Initializes the Google Mobile Ads SDK and preloads a post-song interstitial ad.
    func startIfNeeded() {
        guard configuration.isEnabled, !isSDKInitialized else { return }
        isSDKInitialized = true

        guard !AppEnvironment.isUITesting else { return }

        #if canImport(GoogleMobileAds)
        Task { @MainActor [weak self] in
            _ = await MobileAds.shared.start()
            await self?.preloadInterstitial()
        }
        #endif
    }

    /// Updates whether active piano gameplay is currently running so no fullscreen ad can interrupt it.
    func updatePlaybackState(_ state: PlaybackState) {
        if AdPlacementPolicy.isGameplayActive(in: state) {
            activeGameplayLockCount = 1
        } else {
            activeGameplayLockCount = 0
        }
    }

    /// Called only when a song reaches `.finished`. Increments the completion counter and presents
    /// a preloaded interstitial ad if allowed by `AdPlacementPolicy`.
    func handleSongFinished(in state: PlaybackState) {
        guard state == .finished else { return }
        completedSongsSinceLastInterstitial += 1

        let elapsed = lastInterstitialPresentedAt.map { Date().timeIntervalSince($0) }
        guard !isGameplayActive,
              AdPlacementPolicy.allowsPostSongInterstitial(
                  for: state,
                  adsEnabled: configuration.isEnabled,
                  completedSongsSinceLastAd: completedSongsSinceLastInterstitial,
                  minimumSongsBetweenInterstitials: 2,
                  secondsSinceLastInterstitial: elapsed,
                  minimumCooldownSeconds: 90
              )
        else { return }

        presentInterstitialIfReady(for: state)
    }

    func preloadInterstitial() async {
        guard configuration.isEnabled, !AppEnvironment.isUITesting else { return }
        #if canImport(GoogleMobileAds)
        let adUnitID = configuration.interstitialAdUnitID
        do {
            let ad = try await InterstitialAd.load(with: adUnitID, request: Request())
            self.interstitialAd = ad
            self.isInterstitialLoaded = true
        } catch {
            self.interstitialAd = nil
            self.isInterstitialLoaded = false
        }
        #endif
    }

    private func presentInterstitialIfReady(for state: PlaybackState) {
        guard state == .finished, !isGameplayActive, !AppEnvironment.isUITesting else { return }
        #if canImport(GoogleMobileAds)
        guard let interstitialAd,
              let rootViewController = Self.topViewController()
        else {
            Task { @MainActor [weak self] in
                await self?.preloadInterstitial()
            }
            return
        }
        completedSongsSinceLastInterstitial = 0
        lastInterstitialPresentedAt = Date()
        self.interstitialAd = nil
        self.isInterstitialLoaded = false
        interstitialAd.present(from: rootViewController)
        Task { @MainActor [weak self] in
            await self?.preloadInterstitial()
        }
        #endif
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
