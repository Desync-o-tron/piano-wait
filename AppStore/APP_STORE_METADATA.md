# App Store Connect Metadata & Submission Guide — free MIDI player (FOSS)

## App Identity & Signing

| Field | Value |
| :--- | :--- |
| **App Display Name** | `free MIDI player (FOSS)` |
| **Subtitle** | `Piano Practice & Wait Mode` |
| **Bundle Identifier** | `com.lukeknoble.freemidiplayer` |
| **Apple Developer Team ID** | `QKZ4JTYUVM` (GENERAL NEURO INC) |
| **Primary Category** | Music (`MZGenre.Music`) |
| **Secondary Category** | Education (`MZGenre.Education`) |
| **Version / Build** | `1.0` (`1`) |
| **Age Rating** | `4+` (No objectionable content) |
| **Price** | Free (Ad-supported via Google AdMob) |
| **Encryption (`ITSAppUsesNonExemptEncryption`)** | `false` (Standard HTTPS/TLS only) |

---

## AdMob Configuration (`App/Info.plist`)

The app is pre-configured with Google's official iOS test IDs in `App/Info.plist` so builds run out of the box without policy violations during development and review. Before turning on live production ads, replace the three values in `App/Info.plist`:

| `Info.plist` Key | Current Value (Google Official Test ID) | Purpose |
| :--- | :--- | :--- |
| `GADApplicationIdentifier` | `ca-app-pub-3940256099942544~1458002511` | AdMob App ID |
| `AdMobBannerAdUnitID` | `ca-app-pub-3940256099942544/2435281174` | Adaptive Banner in `LibraryView` & `PostSongSummaryCard` |
| `AdMobInterstitialAdUnitID` | `ca-app-pub-3940256099942544/4411468910` | Post-song completion Interstitial Ad |
| `AdsEnabled` | `true` | Master toggle (`--disable-ads` launch arg disables at runtime) |

### Strict Gameplay Protection Policy (`AdPlacementPolicy`)
- **Library Screen (`LibraryView`)**: Shows a single anchored bottom `AdBannerView` via `.safeAreaInset(edge: .bottom)`.
- **Active Practice (`PracticeView` in `.paused`, `.playing`, or `.waiting` states)**: **Zero ads.** No banner and no interstitial can ever appear while practicing.
- **Post-Song Completion (`PracticeView` in `.finished` state)**: Displays `PostSongSummaryCard` with session stats, an inline `AdBannerView`, and (at most once every 2 completed songs with a 90-second cooldown) a preloaded AdMob interstitial.

---

## App Store Listing Copy (`en-US`)

### Name (30 chars max)
`free MIDI player (FOSS)`

### Subtitle (30 chars max)
`Piano Practice & Wait Mode`

### Promotional Text (170 chars max)
Import any MIDI song, place your iPhone or iPad on your acoustic piano, and practice hands-separate or together with real-time Wait-for-Me note detection.

### Description
free MIDI player (FOSS) turns any Standard MIDI File (.mid / .midi) into an interactive falling-note piano lesson that listens to your real acoustic piano or keyboard through the microphone.

FEATURES:
• Real-Time Acoustic Piano Pitch Detection: Place your iPhone or iPad on your piano music stand—no cables or MIDI adapters required. Advanced polyphonic pitch detection listens for single notes and full two-hand chords, automatically adapting to your piano's tuning.
• Wait-for-Me Practice Mode: Falling notes pause at each step and wait until you strike the right keys on your piano, with forgiving rolled-chord grace.
• Continuous Play-Along Mode: Practice at your own pace from 0.25x to 2.0x speed, set A–B section loops on tricky measures, and scrub smoothly through any piece.
• Left & Right Hand Isolation: Practice Left Hand, Right Hand, or Both Hands, with an optional built-in piano synthesizer to auto-play the other hand's accompaniment.
• Import Any MIDI File: Ships with built-in classical favorites (Ode to Joy, Bach's Minuet in G, Beethoven's Für Elise) and lets you import any .mid or .midi file directly from the iOS Files app.
• Zoomable 88-Key Viewport: Pinch to zoom the keyboard to fit the active song's range or view all 88 keys in portrait or landscape.

### Keywords (100 chars max)
`midi,piano,practice,sheet music,falling notes,chords,pitch,acoustic,learn,keyboard,player,tutor`

### App Review Notes
- **Testing without a physical piano**: You can test every feature directly in the app without an acoustic piano—either tap the on-screen piano keys at the bottom of the Practice screen to play notes, tap the **Skip Step** (`>|`) button in Wait-for-Me mode, or toggle **Wait for Me** off + enable the speaker icon (**Reference audio**) to hear the built-in piano synthesizer play the song automatically.
- **Microphone Permission**: Used exclusively for real-time on-device FFT pitch detection (`vDSP`) so the app can advance when the user plays the expected chord on an acoustic piano. Audio is never recorded or transmitted.
