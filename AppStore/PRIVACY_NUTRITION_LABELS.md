# Privacy Nutrition Labels — free MIDI player (FOSS)

This document provides the exact App Store Connect **App Privacy (Nutrition Labels)** configuration and technical justification for **free MIDI player (FOSS)** (`com.lukeknoble.freemidiplayer`), matching the bundled `App/PrivacyInfo.xcprivacy` manifest.

---

## 1. Microphone & Audio Data (Ephemeral On-Device DSP Only)

- **Permission Prompt (`NSMicrophoneUsageDescription`)**:
  > *"free MIDI player (FOSS) listens to your piano so it can wait for you to play the right notes."*
- **Is Audio Data collected off-device?** **No**
- **Why Audio Data is NOT marked as "Collected" in App Store Connect**:
  - Microphone audio is captured via `AVAudioEngine` and analyzed in real time on the device using Apple's `Accelerate` (`vDSP`) FFT spectrum analyzer (`AcousticPitchDetector`).
  - Audio PCM buffers exist only in volatile memory (~93 ms sliding windows) to identify which piano pitches are sounding, and are immediately discarded.
  - **No audio recordings are ever saved to disk or transmitted over the network.**
  - Under Apple's [App Privacy Details specification](https://developer.apple.com/app-store/app-privacy-details/), data that is processed strictly on-device and never transmitted off the device is not disclosed as "Collected".

---

## 2. Advertising & Analytics Data (Google Mobile Ads / AdMob)

Because **free MIDI player (FOSS)** integrates the **Google Mobile Ads SDK** (`GoogleMobileAds` 12.x) to display non-intrusive banner ads in `LibraryView` and post-song summary ads after song completion, declare the following data types in **App Store Connect → App Privacy**:

### Questionnaire Summary

- **Do you or your third-party partners collect data from this app?**
  - **Yes**

### Data Types to Select

| Category | Data Type | Linked to User? | Used for Tracking? | Purposes |
| :--- | :--- | :--- | :--- | :--- |
| **Location** | **Coarse Location** *(IP-based approximate region)* | No | No | Third-Party Advertising, Analytics |
| **Identifiers** | **Device ID** *(Vendor / Advertising ID)* | No | No | Third-Party Advertising, Analytics |
| **Usage Data** | **Product Interaction** *(App launch, ad views/taps)* | No | No | Third-Party Advertising, Analytics |
| **Usage Data** | **Advertising Data** *(Ads displayed in library & post-song summary)* | No | No | Third-Party Advertising, Analytics |
| **Diagnostics** | **Crash Data & Performance Data** *(Ad SDK load latency & stability)* | No | No | App Functionality, Analytics |

> **Note on App Tracking Transparency (ATT)**:
> By default, `NSPrivacyTracking` in `App/PrivacyInfo.xcprivacy` is set to `false` and the app serves contextual/non-personalized AdMob ads without interrupting the user on first launch with an ATT tracking prompt. `NSUserTrackingUsageDescription` is included in `App/Info.plist` if personalized tracking is later enabled.

---

## 3. Bundled Privacy Manifest (`App/PrivacyInfo.xcprivacy`)

Apple requires a `PrivacyInfo.xcprivacy` file in the app bundle declaring both collected data types and Required Reason APIs used by the app and embedded SDKs (`GoogleMobileAds` / `UserMessagingPlatform`):

| Required Reason API Category | Declared Reason Code | Usage |
| :--- | :--- | :--- |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | Checking modification dates of imported/cached `.mid` files inside the app container (`Documents/MIDIs`). |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | Accessing `UserDefaults` scoped to the app itself and Google Mobile Ads SDK caching. |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | Measuring elapsed time intervals during practice playback and SDK latency. |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `E174.1` | Used by Google Mobile Ads SDK for local ad asset cache management. |
