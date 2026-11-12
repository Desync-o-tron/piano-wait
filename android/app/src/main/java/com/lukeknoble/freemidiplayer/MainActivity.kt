package com.lukeknoble.freemidiplayer

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.lukeknoble.freemidiplayer.ads.AdManager
import com.lukeknoble.freemidiplayer.audio.HardwareMidiController
import com.lukeknoble.freemidiplayer.audio.PianoSynth
import com.lukeknoble.freemidiplayer.config.RemoteConfigLoader
import com.lukeknoble.freemidiplayer.engine.AdPlacementPolicy
import com.lukeknoble.freemidiplayer.engine.HandSelection
import com.lukeknoble.freemidiplayer.engine.PlaybackMode
import com.lukeknoble.freemidiplayer.engine.PlaybackState
import com.lukeknoble.freemidiplayer.engine.PracticeEvent
import com.lukeknoble.freemidiplayer.engine.WaitModeEngine
import com.lukeknoble.freemidiplayer.layout.PracticeZoom
import com.lukeknoble.freemidiplayer.midi.LibrarySongItem
import com.lukeknoble.freemidiplayer.midi.MidiNote
import com.lukeknoble.freemidiplayer.midi.MidiParser
import com.lukeknoble.freemidiplayer.midi.MidiSong
import com.lukeknoble.freemidiplayer.telemetry.PracticeTelemetryLogger
import com.lukeknoble.freemidiplayer.ui.FallingNotesView
import com.lukeknoble.freemidiplayer.ui.PianoKeyboardView
import java.io.File
import java.util.Locale
import kotlin.math.roundToInt

class MainActivity : AppCompatActivity() {

    private lateinit var rootContainer: FrameLayout
    private val synth = PianoSynth()
    private var hardwareMidi: HardwareMidiController? = null

    private var activeEngine: WaitModeEngine? = null
    private var activeZoom: PracticeZoom? = null
    private var activeTelemetry: PracticeTelemetryLogger? = null
    private var fallingNotesView: FallingNotesView? = null
    private var keyboardView: PianoKeyboardView? = null
    private var trackedStepIndex: Int? = null
    private var trackedStepEnteredAtMs: Long = 0L
    private val trackedStepHeard = mutableSetOf<Int>()
    private val trackedStepLatched = mutableSetOf<Int>()
    private var trackedStepPeakRms: Float = 0f

    private var statusPromptView: TextView? = null
    private var statusMetricsView: TextView? = null
    private var playPauseButton: Button? = null
    private var skipButton: Button? = null
    private var waitModeButton: Button? = null
    private var speedButton: Button? = null
    private var handButton: Button? = null
    private var loopButton: Button? = null
    private var micButton: Button? = null
    private var summaryOverlay: View? = null

    private var loopStartMarker: Double? = null
    private var loopEndMarker: Double? = null
    private var lastFrameNanos: Long = 0L
    private var wasFinishedNotified = false
    private var autoPanKeyboardToExpectedNotes = true
    private var showUpcomingStepHighlight = true

    private val builtInSongs = listOf(
        LibrarySongItem(
            id = "dark-is-the-night",
            title = "Dark Is the Night",
            composer = "Nikita Bogoslovsky",
            assetFileName = "songs/dark_is_the_night.mid"
        ),
        LibrarySongItem(
            id = "ode-to-joy",
            title = "Ode to Joy",
            composer = "Ludwig van Beethoven",
            assetFileName = "songs/ode_to_joy.mid"
        ),
        LibrarySongItem(
            id = "minuet-in-g",
            title = "Minuet in G Major",
            composer = "J.S. Bach (attr. Petzold)",
            assetFileName = "songs/minuet_in_g.mid"
        ),
        LibrarySongItem(
            id = "fur-elise",
            title = "Für Elise (Opening)",
            composer = "Ludwig van Beethoven",
            assetFileName = "songs/fur_elise_opening.mid"
        ),
        LibrarySongItem(
            id = "prelude-in-c",
            title = "Prelude in C Major (BWV 846)",
            composer = "J.S. Bach",
            assetFileName = "songs/prelude_in_c.mid"
        ),
        LibrarySongItem(
            id = "twinkle-twinkle",
            title = "Twinkle Twinkle Little Star",
            composer = "Traditional",
            assetFileName = "songs/twinkle_twinkle.mid"
        ),
        LibrarySongItem(
            id = "chord-drill",
            title = "Two-Hand Chord Progression Drill",
            composer = "free MIDI player (FOSS)",
            assetFileName = "songs/chord_drill.mid"
        )
    )

    private val openMidiDocumentLauncher = registerForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris: List<Uri> ->
        if (uris.isNotEmpty()) {
            var importedCount = 0
            for (uri in uris) {
                if (importMidiUri(uri)) importedCount += 1
            }
            if (importedCount > 0) {
                Toast.makeText(
                    this,
                    "Imported $importedCount MIDI file(s)",
                    Toast.LENGTH_SHORT
                ).show()
                showLibraryScreen()
            }
        }
    }

    private val micPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted: Boolean ->
        if (granted) {
            hardwareMidi?.startMicrophone()
            updateControlLabels()
            maybePromptTelemetryOptIn()
        } else {
            Toast.makeText(
                this,
                "Microphone permission is only needed for acoustic piano pitch detection.",
                Toast.LENGTH_SHORT
            ).show()
        }
    }

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            val engine = activeEngine ?: return
            val dt = if (lastFrameNanos == 0L) {
                1.0 / 60.0
            } else {
                ((frameTimeNanos - lastFrameNanos) / 1_000_000_000.0).coerceIn(0.0, 0.1)
            }
            lastFrameNanos = frameTimeNanos

            val events = engine.tick(dt)
            handlePracticeEvents(events, engine)
            updateTelemetryTracking(engine)

            if (autoPanKeyboardToExpectedNotes) {
                val targetNotes = if (engine.waitingNotes.isNotEmpty()) {
                    engine.waitingNotes
                } else if (showUpcomingStepHighlight) {
                    engine.upcomingNotes
                } else {
                    emptySet()
                }
                if (targetNotes.isNotEmpty()) {
                    activeZoom?.let { zoom ->
                        zoom.keyboard = zoom.keyboard.ensuringVisible(targetNotes)
                    }
                }
            }

            fallingNotesView?.invalidate()
            keyboardView?.invalidate()
            updateStatusText(engine)

            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        AdManager.initialize(this)
        synth.start()

        hardwareMidi = HardwareMidiController(
            context = this,
            onNoteOn = { pitch, velocity ->
                synth.noteOn(pitch, velocity)
                activeEngine?.registerKeyPress(pitch)
                keyboardView?.pressedKeys?.add(pitch)
                keyboardView?.invalidate()
                fallingNotesView?.invalidate()
            },
            onNoteOff = { pitch ->
                synth.noteOff(pitch)
                keyboardView?.pressedKeys?.remove(pitch)
                keyboardView?.invalidate()
            },
            onMicNotesDetected = { detected ->
                keyboardView?.heardNotes = detected
                if (activeEngine?.state == PlaybackState.WAITING) {
                    trackedStepHeard.addAll(detected)
                    val rms = hardwareMidi?.latestMicRms ?: 0f
                    if (rms > trackedStepPeakRms) trackedStepPeakRms = rms
                }
                activeEngine?.ingest(heard = detected, onsets = detected, matchedExpected = detected)
                keyboardView?.invalidate()
                fallingNotesView?.invalidate()
            },
            onDeviceStatusChanged = { _ ->
                updateControlLabels()
            }
        ).also { it.startMidiDiscovery() }

        rootContainer = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(10, 13, 23))
        }
        setContentView(rootContainer)

        // Handle incoming VIEW intent if user opened a .mid file directly
        val incomingUri = intent?.data
        if (incomingUri != null && intent?.action == Intent.ACTION_VIEW) {
            importMidiUri(incomingUri)
        }

        showLibraryScreen()
    }

    override fun onPause() {
        super.onPause()
        activeEngine?.pause()
        synth.allNotesOff()
        updateControlLabels()
    }

    override fun onDestroy() {
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        hardwareMidi?.stopAll()
        synth.stop()
        super.onDestroy()
    }

    override fun onBackPressed() {
        if (activeEngine != null) {
            showLibraryScreen()
        } else {
            super.onBackPressed()
        }
    }

    // =========================================================================
    // Song Library Screen
    // =========================================================================

    private fun showLibraryScreen() {
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        synth.allNotesOff()
        activeEngine = null
        activeZoom = null
        fallingNotesView = null
        keyboardView = null
        summaryOverlay = null
        AdManager.updatePlaybackState(PlaybackState.PAUSED)

        rootContainer.removeAllViews()

        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(10, 13, 23))
        }

        // Top Bar
        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(14))
            setBackgroundColor(Color.rgb(15, 20, 34))
        }

        val titleCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        titleCol.addView(TextView(this).apply {
            text = BuildConfig.APP_DISPLAY_NAME
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 21f)
            setTypeface(typeface, Typeface.BOLD)
        })
        titleCol.addView(TextView(this).apply {
            text = "Interactive Wait-for-Me & Play-Along MIDI Trainer"
            setTextColor(Color.rgb(155, 175, 215))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
        })
        topBar.addView(titleCol)

        val importBtn = makePillButton("Import .mid", accent = true) {
            openMidiDocumentLauncher.launch(
                arrayOf("audio/midi", "audio/x-midi", "application/x-midi", "*/*")
            )
        }
        topBar.addView(importBtn)
        page.addView(topBar)

        // Scrollable Song List
        val scroll = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
        }
        val listLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(24))
        }

        listLayout.addView(makeSectionHeader("BUILT-IN CLASSICAL LIBRARY"))
        for (item in builtInSongs) {
            listLayout.addView(makeSongCard(item))
        }

        val imported = loadImportedSongItems()
        listLayout.addView(makeSectionHeader("IMPORTED MIDI FILES (${imported.size})"))
        if (imported.isEmpty()) {
            listLayout.addView(TextView(this).apply {
                text = "Tap \"Import .mid\" above to load any Standard MIDI (.mid / .midi) song from your device."
                setTextColor(Color.rgb(140, 155, 185))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
                setPadding(dp(8), dp(8), dp(8), dp(16))
            })
        } else {
            for (item in imported) {
                listLayout.addView(makeSongCard(item))
            }
        }

        listLayout.addView(makeSectionHeader("MICROPHONE AI IMPROVEMENT"))
        listLayout.addView(makeTelemetryOptInCard())

        scroll.addView(listLayout)
        page.addView(scroll)

        // Bottom AdMob Banner (Library placement only)
        val bannerHolder = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(14, 18, 30))
            setPadding(0, dp(4), 0, dp(4))
        }
        bannerHolder.addView(AdManager.createBannerView(this))
        page.addView(bannerHolder)

        rootContainer.addView(page)
    }

    private fun makeSectionHeader(label: String): TextView {
        return TextView(this).apply {
            text = label
            setTextColor(Color.rgb(120, 145, 195))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(6), dp(14), dp(6), dp(8))
        }
    }

    private fun makeSongCard(item: LibrarySongItem): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = roundedBg(Color.rgb(20, 27, 45), dp(12), Color.argb(40, 120, 155, 230))
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            lp.bottomMargin = dp(10)
            layoutParams = lp
            isClickable = true
            isFocusable = true
            setOnClickListener { openSong(item) }
        }

        val infoCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }

        val parsedSummary = try {
            val s = loadSongData(item)
            "${s.noteCount} notes • ${s.steps.size} steps • ${formatSeconds(s.durationSeconds)}"
        } catch (_: Exception) {
            "Standard MIDI File"
        }

        infoCol.addView(TextView(this).apply {
            text = item.title
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16.5f)
            setTypeface(typeface, Typeface.BOLD)
        })
        infoCol.addView(TextView(this).apply {
            text = "${item.composer}  •  $parsedSummary"
            setTextColor(Color.rgb(160, 180, 215))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        })
        card.addView(infoCol)

        if (!item.isBuiltIn && item.localFilePath != null) {
            val delBtn = makePillButton("Delete", accent = false) {
                File(item.localFilePath).delete()
                showLibraryScreen()
            }
            card.addView(delBtn)
        } else {
            card.addView(TextView(this).apply {
                text = "Practice ›"
                setTextColor(Color.rgb(46, 242, 173))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, Typeface.BOLD)
                setPadding(dp(12), 0, 0, 0)
            })
        }

        return card
    }

    private fun loadSongData(item: LibrarySongItem): MidiSong {
        val bytes = when {
            item.assetFileName != null -> assets.open(item.assetFileName).use { it.readBytes() }
            item.localFilePath != null -> File(item.localFilePath).readBytes()
            else -> throw IllegalArgumentException("Missing song source")
        }
        return MidiParser.parse(bytes = bytes, title = item.title, composer = item.composer)
    }

    private fun importMidiUri(uri: Uri): Boolean {
        return try {
            val rawName = queryDisplayName(uri) ?: "imported_${System.currentTimeMillis()}.mid"
            val cleanTitle = rawName.removeSuffix(".mid").removeSuffix(".midi")
                .replace('_', ' ').replace('-', ' ').trim().ifEmpty { "Imported MIDI" }
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return false
            // Validate MIDI parse before saving
            MidiParser.parse(bytes = bytes, title = cleanTitle)

            val dir = File(filesDir, "imported_songs").apply { mkdirs() }
            val safeFile = File(dir, "${System.currentTimeMillis()}_${rawName.replace(Regex("[^A-Za-z0-9._-]"), "_")}")
            safeFile.writeBytes(bytes)
            true
        } catch (e: Exception) {
            Toast.makeText(this, "Could not import MIDI: ${e.message}", Toast.LENGTH_LONG).show()
            false
        }
    }

    private fun loadImportedSongItems(): List<LibrarySongItem> {
        val dir = File(filesDir, "imported_songs")
        if (!dir.exists()) return emptyList()
        return dir.listFiles()
            ?.filter { it.isFile && (it.name.endsWith(".mid", true) || it.name.endsWith(".midi", true)) }
            ?.sortedByDescending { it.lastModified() }
            ?.map { file ->
                val raw = file.name.substringAfter('_')
                    .removeSuffix(".mid").removeSuffix(".midi")
                    .replace('_', ' ')
                LibrarySongItem(
                    id = file.name,
                    title = raw.ifBlank { file.name },
                    composer = "Imported MIDI",
                    localFilePath = file.absolutePath,
                    isBuiltIn = false
                )
            } ?: emptyList()
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (_: Exception) {
            uri.lastPathSegment
        }
    }

    // =========================================================================
    // Practice Screen (Wait-for-Me + Continuous + 60fps Falling Notes + 88 Keys)
    // =========================================================================

    private fun openSong(item: LibrarySongItem) {
        val song = try {
            loadSongData(item)
        } catch (e: Exception) {
            Toast.makeText(this, "Error loading MIDI: ${e.message}", Toast.LENGTH_LONG).show()
            return
        }

        val engine = WaitModeEngine(song = song, mode = PlaybackMode.WAIT_FOR_ME)
        RemoteConfigLoader.latest.applyTo(engine.configuration)
        val zoom = PracticeZoom(song = song)
        val telemetry = PracticeTelemetryLogger(this, songTitle = song.title)
        activeEngine = engine
        activeZoom = zoom
        activeTelemetry = telemetry
        trackedStepIndex = null
        RemoteConfigLoader.refreshAsync(this) { ota ->
            ota.applyTo(engine.configuration)
            ota.autoPanKeyboardToExpectedNotes?.let { autoPanKeyboardToExpectedNotes = it }
            ota.showUpcomingStepHighlight?.let { showUpcomingStepHighlight = it }
            ota.telemetryEnabled?.let { telemetry.isOtaEnabled = it }
            ota.telemetryFlushStepInterval?.let { if (it >= 1) telemetry.flushStepInterval = it }
            ota.telemetryUploadAudioSnippets?.let { telemetry.isAudioUploadEnabled = it }
            ota.telemetryBucket?.let { if (it.isNotBlank()) telemetry.bucket = it }
        }
        loopStartMarker = null
        loopEndMarker = null
        wasFinishedNotified = false
        lastFrameNanos = 0L

        rootContainer.removeAllViews()

        val practiceRoot = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(10, 13, 23))
        }

        // 1. Scrollable Control Bar
        val controlScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(Color.rgb(16, 21, 36))
        }
        val controlRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(8), dp(10), dp(8))
        }

        controlRow.addView(makePillButton("‹ Library") { showLibraryScreen() })
        addSpacer(controlRow, 6)

        playPauseButton = makePillButton("⏸ Pause", accent = true) {
            if (engine.state == PlaybackState.PLAYING || engine.state == PlaybackState.WAITING) {
                engine.pause()
            } else {
                if (engine.state == PlaybackState.FINISHED) {
                    engine.restart()
                    wasFinishedNotified = false
                    summaryOverlay?.visibility = View.GONE
                }
                engine.play()
            }
            AdManager.updatePlaybackState(engine.state)
            updateControlLabels()
        }
        controlRow.addView(playPauseButton)
        addSpacer(controlRow, 6)

        controlRow.addView(makePillButton("⏮ Restart") {
            synth.allNotesOff()
            engine.restart()
            engine.play()
            wasFinishedNotified = false
            summaryOverlay?.visibility = View.GONE
            AdManager.updatePlaybackState(engine.state)
            updateControlLabels()
        })
        addSpacer(controlRow, 6)

        skipButton = makePillButton("⏭ Skip") {
            engine.currentStepIndex?.let { stepIdx ->
                recordAndroidStepDiagnostic(engine, stepIdx, "skipped")
            }
            engine.skipStep()
            handlePracticeEvents(engine.drainEvents(), engine)
            updateControlLabels()
        }
        controlRow.addView(skipButton)
        addSpacer(controlRow, 8)

        waitModeButton = makePillButton("Wait for Me: ON", accent = true) {
            val nextMode = if (engine.mode == PlaybackMode.WAIT_FOR_ME) {
                PlaybackMode.CONTINUOUS
            } else {
                PlaybackMode.WAIT_FOR_ME
            }
            engine.updateMode(nextMode)
            updateControlLabels()
        }
        controlRow.addView(waitModeButton)
        addSpacer(controlRow, 6)

        speedButton = makePillButton("Tempo 100%") {
            showSpeedDialog(engine)
        }
        controlRow.addView(speedButton)
        addSpacer(controlRow, 6)

        controlRow.addView(makePillButton("🔍 Zoom") {
            showZoomDialog(zoom)
        })
        addSpacer(controlRow, 6)

        handButton = makePillButton("Hands: Both") {
            showHandDialog(engine)
        }
        controlRow.addView(handButton)
        addSpacer(controlRow, 6)

        loopButton = makePillButton("Loop A-B") {
            cycleLoopState(engine)
        }
        controlRow.addView(loopButton)
        addSpacer(controlRow, 6)

        micButton = makePillButton("🎤 Mic") {
            toggleMicrophone()
        }
        controlRow.addView(micButton)

        controlScroll.addView(controlRow)
        practiceRoot.addView(controlScroll)

        // 2. Status Bar
        val statusBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(6), dp(14), dp(6))
            setBackgroundColor(Color.rgb(13, 17, 29))
        }
        statusPromptView = TextView(this).apply {
            text = song.title
            setTextColor(Color.rgb(255, 204, 56))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTypeface(typeface, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        statusMetricsView = TextView(this).apply {
            text = "Accuracy 100% • Streak 0"
            setTextColor(Color.rgb(175, 195, 230))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
        }
        statusBar.addView(statusPromptView)
        statusBar.addView(statusMetricsView)
        practiceRoot.addView(statusBar)

        // 3. Center Canvas Area (Falling Notes + Post-Song Completion Summary Overlay)
        val centerFrame = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
        }

        val fnView = FallingNotesView(
            context = this,
            engine = engine,
            zoom = zoom,
            onViewportChanged = { keyboardView?.invalidate() }
        )
        fallingNotesView = fnView
        centerFrame.addView(fnView, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))

        val summaryCard = buildPostSongSummaryOverlay(engine)
        summaryCard.visibility = View.GONE
        summaryOverlay = summaryCard
        centerFrame.addView(summaryCard)

        practiceRoot.addView(centerFrame)

        // 4. Interactive 88-Key Piano Keyboard
        val kbHeight = (resources.displayMetrics.heightPixels * 0.24f).toInt().coerceIn(dp(130), dp(195))
        val kbView = PianoKeyboardView(
            context = this,
            engine = engine,
            zoom = zoom,
            onKeyPressed = { note ->
                synth.noteOn(note, 92)
                engine.registerKeyPress(note)
                handlePracticeEvents(engine.drainEvents(), engine)
                fallingNotesView?.invalidate()
                updateStatusText(engine)
            },
            onKeyReleased = { note ->
                synth.noteOff(note)
            },
            onViewportChanged = { fallingNotesView?.invalidate() }
        )
        keyboardView = kbView
        practiceRoot.addView(kbView, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            kbHeight
        ))

        rootContainer.addView(practiceRoot)

        // Start playback immediately in Wait-for-Me mode
        engine.play()
        AdManager.updatePlaybackState(engine.state)
        updateControlLabels()
        updateStatusText(engine)
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    private fun handlePracticeEvents(events: List<PracticeEvent>, engine: WaitModeEngine) {
        for (ev in events) {
            when (ev) {
                is PracticeEvent.PlayNote -> {
                    synth.noteOn(ev.pitch, ev.velocity, ev.duration)
                }
                is PracticeEvent.StepCompleted -> {
                    // Play the completed chord notes on the built-in synth if user tapped or matched
                }
                is PracticeEvent.Looped -> {
                }
                is PracticeEvent.Finished -> {
                    activeTelemetry?.let { tel ->
                        Thread {
                            tel.uploadSnapshotSync(engine.handSelection.label, engine.stats, force = true)
                        }.start()
                    }
                    AdManager.updatePlaybackState(PlaybackState.FINISHED)
                    if (!wasFinishedNotified) {
                        wasFinishedNotified = true
                        showPostSongSummary(engine)
                        AdManager.handleSongFinished(this, PlaybackState.FINISHED)
                    }
                    updateControlLabels()
                }
            }
        }
    }

    private fun updateStatusText(engine: WaitModeEngine) {
        val prompt = when (engine.state) {
            PlaybackState.WAITING -> {
                val needed = engine.waitingNotes.minus(engine.latched).sorted()
                if (needed.isEmpty()) "Waiting..."
                else "Play: ${needed.joinToString(" + ") { MidiNote.name(it) }}"
            }
            PlaybackState.PLAYING -> {
                if (engine.mode == PlaybackMode.CONTINUOUS) {
                    "Play Along (${(engine.speed * 100).roundToInt()}%)"
                } else {
                    "Playing..."
                }
            }
            PlaybackState.PAUSED -> "Paused — Tap Play or strike expected keys"
            PlaybackState.FINISHED -> "Song Complete!"
        }
        statusPromptView?.text = prompt

        val pct = (engine.stats.accuracy * 100.0).roundToInt()
        val prog = (engine.progress * 100.0).roundToInt()
        statusMetricsView?.text =
            "Progress $prog%  •  Accuracy $pct%  •  Hit ${engine.stats.notesHit}  •  Streak ${engine.stats.currentStreak}"
    }

    private fun updateControlLabels() {
        val engine = activeEngine ?: return
        val running = engine.state == PlaybackState.PLAYING || engine.state == PlaybackState.WAITING
        playPauseButton?.text = if (running) "⏸ Pause" else "▶ Play"
        skipButton?.isEnabled = engine.mode == PlaybackMode.WAIT_FOR_ME && engine.state != PlaybackState.FINISHED
        waitModeButton?.text = if (engine.mode == PlaybackMode.WAIT_FOR_ME) {
            "Wait for Me: ON"
        } else {
            "Continuous Mode"
        }
        speedButton?.text = "Tempo ${(engine.speed * 100).roundToInt()}%"
        handButton?.text = "Hands: ${engine.handSelection.label}"
        loopButton?.text = when {
            loopStartMarker != null && loopEndMarker != null -> "Loop: Clear"
            loopStartMarker != null -> "Loop: Set B"
            else -> "Loop: Set A"
        }
        val micOn = hardwareMidi?.isMicActive == true
        val midiCount = hardwareMidi?.connectedMidiDeviceCount ?: 0
        micButton?.text = when {
            micOn && midiCount > 0 -> "🎤 Mic ON • MIDI($midiCount)"
            micOn -> "🎤 Mic: ON"
            midiCount > 0 -> "🎹 MIDI($midiCount) • Mic"
            else -> "🎤 Mic: OFF"
        }
    }

    // =========================================================================
    // Dialogs & Popovers (Speed 25%-200%, Zoom/Lookahead, Hands, A-B Loop)
    // =========================================================================

    private fun showSpeedDialog(engine: WaitModeEngine) {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(12))
        }
        val label = TextView(this).apply {
            text = "Tempo: ${(engine.speed * 100).roundToInt()}% (${String.format(Locale.US, "%.2fx", engine.speed)})"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTypeface(typeface, Typeface.BOLD)
        }
        container.addView(label)

        val seek = SeekBar(this).apply {
            max = 175 // 25% to 200%
            progress = ((engine.speed * 100).roundToInt() - 25).coerceIn(0, 175)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, value: Int, fromUser: Boolean) {
                    val pct = 25 + value
                    engine.updateSpeed(pct / 100.0)
                    label.text = "Tempo: $pct% (${String.format(Locale.US, "%.2fx", engine.speed)})"
                    updateControlLabels()
                }
                override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                override fun onStopTrackingTouch(seekBar: SeekBar?) {}
            })
        }
        container.addView(seek)

        val presetRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(12), 0, 0)
        }
        for (preset in listOf(0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0)) {
            val btn = Button(this).apply {
                text = "${(preset * 100).toInt()}%"
                textSize = 11f
                setOnClickListener {
                    engine.updateSpeed(preset)
                    seek.progress = ((preset * 100).roundToInt() - 25).coerceIn(0, 175)
                    label.text = "Tempo: ${(preset * 100).toInt()}%"
                    updateControlLabels()
                }
            }
            presetRow.addView(btn, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        container.addView(presetRow)

        AlertDialog.Builder(this)
            .setTitle("Practice Tempo (25% – 200%)")
            .setView(container)
            .setPositiveButton("Done", null)
            .show()
    }

    private fun showZoomDialog(zoom: PracticeZoom) {
        val options = arrayOf(
            "Fit Song Range (Auto-Zoom)",
            "Show All 88 Keys (A0 – C8)",
            "Zoom In (+25%)",
            "Zoom Out (-25%)",
            "Pan Left (Lower Octave)",
            "Pan Right (Higher Octave)",
            "Lookahead: 2.0s (Fast Drop)",
            "Lookahead: 4.0s (Default)",
            "Lookahead: 6.0s (Sight-Reading)"
        )
        AlertDialog.Builder(this)
            .setTitle("Keyboard Viewport & Lookahead")
            .setItems(options) { _, which ->
                when (which) {
                    0 -> zoom.fitSong()
                    1 -> zoom.showAllKeys()
                    2 -> zoom.zoomIn()
                    3 -> zoom.zoomOut()
                    4 -> zoom.panLeft()
                    5 -> zoom.panRight()
                    6 -> zoom.lookaheadSeconds = 2.0
                    7 -> zoom.lookaheadSeconds = 4.0
                    8 -> zoom.lookaheadSeconds = 6.0
                }
                fallingNotesView?.invalidate()
                keyboardView?.invalidate()
            }
            .setPositiveButton("Close", null)
            .show()
    }

    private fun showHandDialog(engine: WaitModeEngine) {
        val options = arrayOf(
            "Both Hands",
            "Right Hand Only (Auto-play Left Hand)",
            "Left Hand Only (Auto-play Right Hand)",
            if (engine.playsReferenceAudio) "Mute Reference Synth in Continuous Mode" else "Enable Reference Synth in Continuous Mode"
        )
        AlertDialog.Builder(this)
            .setTitle("Hand Practice & Accompaniment")
            .setItems(options) { _, which ->
                when (which) {
                    0 -> {
                        engine.updateHandSelection(HandSelection.BOTH)
                    }
                    1 -> {
                        engine.autoPlayAccompaniment = true
                        engine.updateHandSelection(HandSelection.RIGHT)
                    }
                    2 -> {
                        engine.autoPlayAccompaniment = true
                        engine.updateHandSelection(HandSelection.LEFT)
                    }
                    3 -> {
                        engine.playsReferenceAudio = !engine.playsReferenceAudio
                    }
                }
                updateControlLabels()
                fallingNotesView?.invalidate()
                keyboardView?.invalidate()
            }
            .show()
    }

    private fun cycleLoopState(engine: WaitModeEngine) {
        when {
            loopStartMarker == null -> {
                loopStartMarker = engine.playhead.coerceAtLeast(0.0)
                fallingNotesView?.loopStartSeconds = loopStartMarker
                fallingNotesView?.loopEndSeconds = null
            }
            loopEndMarker == null -> {
                val start = loopStartMarker ?: 0.0
                val end = (engine.playhead).coerceAtLeast(start + 1.0)
                if (engine.setLoop(start, end)) {
                    loopEndMarker = end
                    fallingNotesView?.loopEndSeconds = end
                }
            }
            else -> {
                engine.clearLoop()
                loopStartMarker = null
                loopEndMarker = null
                fallingNotesView?.loopStartSeconds = null
                fallingNotesView?.loopEndSeconds = null
            }
        }
        fallingNotesView?.invalidate()
        updateControlLabels()
    }

    private fun toggleMicrophone() {
        val hw = hardwareMidi ?: return
        if (hw.isMicActive) {
            hw.stopMicrophone()
            updateControlLabels()
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            hw.startMicrophone()
            updateControlLabels()
            maybePromptTelemetryOptIn()
        } else {
            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    private fun makeTelemetryOptInCard(): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = roundedBg(Color.rgb(20, 27, 45), dp(12), Color.argb(60, 46, 242, 173))
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            lp.bottomMargin = dp(12)
            layoutParams = lp
        }

        val infoCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        infoCol.addView(TextView(this).apply {
            text = "Help Improve Microphone Pitch Detection"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15.5f)
            setTypeface(typeface, Typeface.BOLD)
        })
        infoCol.addView(TextView(this).apply {
            text = "Share anonymized piano audio snippets & note accuracy data while practicing so we can train a better microphone algorithm."
            setTextColor(Color.rgb(160, 180, 215))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            setPadding(0, dp(3), dp(10), 0)
        })
        card.addView(infoCol)

        val optedIn = PracticeTelemetryLogger.isUserOptedIn(this)
        val toggleBtn = makePillButton(
            label = if (optedIn) "Sharing: ON" else "Opt In",
            accent = optedIn
        ) {
            val next = !PracticeTelemetryLogger.isUserOptedIn(this)
            PracticeTelemetryLogger.setUserOptedIn(this, next)
            showLibraryScreen()
        }
        card.addView(toggleBtn)
        return card
    }

    private fun maybePromptTelemetryOptIn() {
        if (PracticeTelemetryLogger.hasPromptedUser(this)) return
        AlertDialog.Builder(this)
            .setTitle("Help Improve Mic Detection?")
            .setMessage("Would you like to share short anonymized piano audio snippets and note accuracy data while practicing so we can make a better microphone pitch algorithm?")
            .setPositiveButton("Share & Help Improve") { _, _ ->
                PracticeTelemetryLogger.setUserOptedIn(this, true)
                Toast.makeText(this, "Thanks! Mic telemetry sharing enabled.", Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton("Not Now") { _, _ ->
                PracticeTelemetryLogger.setUserOptedIn(this, false)
            }
            .show()
    }

    private fun updateTelemetryTracking(engine: WaitModeEngine) {
        if (engine.state == PlaybackState.WAITING) {
            val step = engine.currentStepIndex
            if (step != null && trackedStepIndex != step) {
                val prev = trackedStepIndex
                if (prev != null && prev < engine.stepStatuses.size) {
                    recordAndroidStepDiagnostic(engine, prev, "completed", trackedStepLatched.toSet())
                }
                trackedStepIndex = step
                trackedStepEnteredAtMs = System.currentTimeMillis()
                trackedStepHeard.clear()
                trackedStepLatched.clear()
                trackedStepPeakRms = 0f
                hardwareMidi?.clearRecentAudio()
            }
            trackedStepLatched.addAll(engine.latched)
        } else {
            val prev = trackedStepIndex
            if (prev != null && prev < engine.stepStatuses.size) {
                recordAndroidStepDiagnostic(engine, prev, "completed", trackedStepLatched.toSet())
            }
            trackedStepIndex = null
        }
    }

    private fun recordAndroidStepDiagnostic(
        engine: WaitModeEngine,
        stepIndex: Int,
        outcome: String,
        overrideLatched: Set<Int>? = null
    ) {
        val tel = activeTelemetry ?: return
        if (stepIndex < 0 || stepIndex >= engine.song.steps.size) return
        val step = engine.song.steps[stepIndex]
        val expected = step.pitches(engine.handSelection)
        val latched = overrideLatched ?: (engine.latched + trackedStepLatched)
        val waitedSec = ((System.currentTimeMillis() - trackedStepEnteredAtMs).coerceAtLeast(0L)) / 1000.0
        val shouldCaptureAudio = PracticeTelemetryLogger.isUserOptedIn(this) &&
            hardwareMidi?.isMicActive == true &&
            (outcome == "skipped" || waitedSec >= 1.5 || expected.size >= 2 || stepIndex % 8 == 0)
        val audioSamples = if (shouldCaptureAudio) {
            hardwareMidi?.snapshotRecentAudio((waitedSec + 0.5).coerceIn(1.5, 3.5))
        } else {
            null
        }
        tel.recordAndUploadAsync(
            stepIndex = stepIndex,
            songTimeSeconds = step.timeSeconds,
            waitedSeconds = waitedSec,
            outcome = outcome,
            expectedNotes = expected,
            latchedNotes = latched,
            heardNotes = trackedStepHeard.toSet(),
            peakRms = trackedStepPeakRms,
            handSelection = engine.handSelection.label,
            stats = engine.stats,
            audioSamples = audioSamples
        )
    }

    // =========================================================================
    // Post-Song Completion Summary Overlay (with AdPlacementPolicy protection)
    // =========================================================================

    private fun buildPostSongSummaryOverlay(engine: WaitModeEngine): View {
        val scrim = FrameLayout(this).apply {
            setBackgroundColor(Color.argb(190, 6, 9, 18))
            isClickable = true
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(22), dp(24), dp(18))
            background = roundedBg(Color.rgb(20, 27, 46), dp(18), Color.argb(90, 46, 242, 173))
            val lp = FrameLayout.LayoutParams(
                dp(360),
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
            layoutParams = lp
        }

        card.addView(TextView(this).apply {
            text = "Practice Complete!"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            setTypeface(typeface, Typeface.BOLD)
        })

        card.addView(TextView(this).apply {
            tag = "summaryStatsText"
            setTextColor(Color.rgb(185, 205, 240))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, dp(16))
        })

        val btnRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        btnRow.addView(makePillButton("Play Again", accent = true) {
            engine.restart()
            engine.play()
            wasFinishedNotified = false
            scrim.visibility = View.GONE
            AdManager.updatePlaybackState(engine.state)
            updateControlLabels()
        })
        addSpacer(btnRow, 12)
        btnRow.addView(makePillButton("Back to Library", accent = false) {
            showLibraryScreen()
        })
        card.addView(btnRow)

        val adContainer = FrameLayout(this).apply {
            setPadding(0, dp(14), 0, 0)
        }
        adContainer.addView(AdManager.createBannerView(this))
        card.addView(adContainer)

        scrim.addView(card)
        return scrim
    }

    private fun showPostSongSummary(engine: WaitModeEngine) {
        if (!AdPlacementPolicy.allowsAdInPracticeView(engine.state)) return
        val overlay = summaryOverlay ?: return
        val statsText = overlay.findViewWithTag<TextView>("summaryStatsText")
        val pct = (engine.stats.accuracy * 100.0).roundToInt()
        statsText?.text =
            "${engine.song.title}\nAccuracy: $pct%  •  Notes Hit: ${engine.stats.notesHit}\nBest Streak: ${engine.stats.bestStreak}  •  Steps Completed: ${engine.stats.stepsCompleted}"
        overlay.visibility = View.VISIBLE
    }

    // =========================================================================
    // UI Helpers
    // =========================================================================

    private fun makePillButton(
        label: String,
        accent: Boolean = false,
        onClick: () -> Unit
    ): Button {
        return Button(this).apply {
            text = label
            isAllCaps = false
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (accent) Color.rgb(10, 16, 26) else Color.WHITE)
            background = roundedBg(
                fillColor = if (accent) Color.rgb(46, 242, 173) else Color.rgb(32, 42, 68),
                radiusPx = dp(20),
                strokeColor = if (accent) Color.TRANSPARENT else Color.argb(60, 255, 255, 255)
            )
            minHeight = dp(36)
            minimumHeight = dp(36)
            setPadding(dp(14), dp(6), dp(14), dp(6))
            setOnClickListener { onClick() }
        }
    }

    private fun roundedBg(fillColor: Int, radiusPx: Int, strokeColor: Int): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = radiusPx.toFloat()
            setColor(fillColor)
            if (strokeColor != Color.TRANSPARENT) {
                setStroke(dp(1), strokeColor)
            }
        }
    }

    private fun addSpacer(parent: LinearLayout, widthDp: Int) {
        parent.addView(
            View(this),
            LinearLayout.LayoutParams(dp(widthDp), 1)
        )
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).roundToInt()
    }

    private fun formatSeconds(sec: Double): String {
        val total = sec.roundToInt().coerceAtLeast(0)
        val m = total / 60
        val s = total % 60
        return String.format(Locale.US, "%d:%02d", m, s)
    }
}
