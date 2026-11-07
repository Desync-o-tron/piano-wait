import PianoWaitCore
import SwiftUI
import UIKit
#if canImport(GoogleMobileAds)
@preconcurrency import GoogleMobileAds
#endif

/// Non-intrusive Google AdMob banner view used only in `LibraryView` and `PostSongSummaryCard`,
/// never during active piano gameplay.
struct AdBannerView: View {
    enum Placement: String {
        case library
        case postSongSummary
    }

    let placement: Placement
    var configuration: AdConfiguration = .current
    @State private var isBannerLoaded = false

    init(placement: Placement = .library, configuration: AdConfiguration = .current) {
        self.placement = placement
        self.configuration = configuration
    }

    var body: some View {
        if configuration.isEnabled {
            ZStack {
                bannerPlaceholder

                #if canImport(GoogleMobileAds)
                if !AppEnvironment.isUITesting {
                    AdMobBannerRepresentable(
                        adUnitID: configuration.bannerAdUnitID,
                        isLoaded: $isBannerLoaded
                    )
                    .frame(height: 50)
                    .opacity(isBannerLoaded ? 1 : 0)
                }
                #endif
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Divider().opacity(0.35)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sponsored advertisement banner")
            .accessibilityIdentifier("adBannerView")
        }
    }

    private var bannerPlaceholder: some View {
        HStack(spacing: 10) {
            Text("AD")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.16), in: .rect(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text("free MIDI player (FOSS) · Supported by Ads")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    configuration.isUsingTestAdUnits
                        ? "AdMob Test Banner (\(placement.rawValue))"
                        : "Sponsored · AdMob"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "pianokeys")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }
}

#if canImport(GoogleMobileAds)
@MainActor
private struct AdMobBannerRepresentable: UIViewRepresentable {
    let adUnitID: String
    @Binding var isLoaded: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoaded: $isLoaded)
    }

    func makeUIView(context: Context) -> BannerView {
        let width = Self.activeBannerWidth()
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        banner.adUnitID = adUnitID
        banner.delegate = context.coordinator
        banner.rootViewController = Self.rootViewController()
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        if uiView.adUnitID != adUnitID {
            uiView.adUnitID = adUnitID
            uiView.load(Request())
        }
    }

    private static func activeBannerWidth() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow), window.bounds.width > 0 {
            return max(320, window.bounds.width)
        }
        if let screen = scenes.first?.screen, screen.bounds.width > 0 {
            return max(320, screen.bounds.width)
        }
        return 320
    }

    private static func rootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
    }

    @MainActor
    final class Coordinator: NSObject, BannerViewDelegate {
        @Binding var isLoaded: Bool

        init(isLoaded: Binding<Bool>) {
            _isLoaded = isLoaded
        }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            isLoaded = true
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            isLoaded = false
        }
    }
}
#endif
