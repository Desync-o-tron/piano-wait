package com.lukeknoble.freemidiplayer.ads

import android.app.Activity
import android.content.Context
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.AdSize
import com.google.android.gms.ads.AdView
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.MobileAds
import com.google.android.gms.ads.interstitial.InterstitialAd
import com.google.android.gms.ads.interstitial.InterstitialAdLoadCallback
import com.lukeknoble.freemidiplayer.BuildConfig
import com.lukeknoble.freemidiplayer.engine.AdPlacementPolicy
import com.lukeknoble.freemidiplayer.engine.PlaybackState

/**
 * Manages Google Mobile Ads (AdMob) banners and post-song interstitials while strictly
 * enforcing [AdPlacementPolicy] so ads never interrupt active piano gameplay.
 */
object AdManager {
    private var initialized = false
    private var currentPlaybackState: PlaybackState = PlaybackState.PAUSED
    private var completedSongsSinceLastAd = 0
    private var lastInterstitialTimestampMs: Long? = null
    private var cachedInterstitial: InterstitialAd? = null
    private var isLoadingInterstitial = false

    fun initialize(context: Context) {
        if (initialized) return
        initialized = true
        try {
            MobileAds.initialize(context.applicationContext) {
                preloadInterstitial(context.applicationContext)
            }
        } catch (_: Exception) {
        }
    }

    fun createBannerView(context: Context): FrameLayout {
        val container = FrameLayout(context).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }
        try {
            val adView = AdView(context).apply {
                setAdSize(AdSize.BANNER)
                adUnitId = BuildConfig.ADMOB_BANNER_UNIT_ID
            }
            val lp = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
            container.addView(adView, lp)
            adView.loadAd(AdRequest.Builder().build())
        } catch (_: Exception) {
        }
        return container
    }

    fun updatePlaybackState(state: PlaybackState) {
        currentPlaybackState = state
    }

    fun handleSongFinished(activity: Activity, state: PlaybackState) {
        currentPlaybackState = state
        if (state != PlaybackState.FINISHED) return

        completedSongsSinceLastAd += 1
        val nowMs = System.currentTimeMillis()
        val elapsedSec = lastInterstitialTimestampMs?.let { (nowMs - it) / 1000.0 }

        val allowed = AdPlacementPolicy.allowsPostSongInterstitial(
            state = currentPlaybackState,
            adsEnabled = true,
            completedSongsSinceLastAd = completedSongsSinceLastAd,
            minimumSongsBetweenInterstitials = 1,
            secondsSinceLastInterstitial = elapsedSec,
            minimumCooldownSeconds = 90.0
        )

        if (!allowed || AdPlacementPolicy.isGameplayActive(currentPlaybackState)) {
            preloadInterstitial(activity.applicationContext)
            return
        }

        val ad = cachedInterstitial
        if (ad != null && !AdPlacementPolicy.isGameplayActive(currentPlaybackState)) {
            cachedInterstitial = null
            completedSongsSinceLastAd = 0
            lastInterstitialTimestampMs = nowMs
            try {
                ad.show(activity)
            } catch (_: Exception) {
            }
        }
        preloadInterstitial(activity.applicationContext)
    }

    private fun preloadInterstitial(context: Context) {
        if (isLoadingInterstitial || cachedInterstitial != null) return
        if (AdPlacementPolicy.isGameplayActive(currentPlaybackState)) return

        isLoadingInterstitial = true
        try {
            InterstitialAd.load(
                context,
                BuildConfig.ADMOB_INTERSTITIAL_UNIT_ID,
                AdRequest.Builder().build(),
                object : InterstitialAdLoadCallback() {
                    override fun onAdLoaded(ad: InterstitialAd) {
                        isLoadingInterstitial = false
                        cachedInterstitial = ad
                    }

                    override fun onAdFailedToLoad(error: LoadAdError) {
                        isLoadingInterstitial = false
                        cachedInterstitial = null
                    }
                }
            )
        } catch (_: Exception) {
            isLoadingInterstitial = false
        }
    }
}
