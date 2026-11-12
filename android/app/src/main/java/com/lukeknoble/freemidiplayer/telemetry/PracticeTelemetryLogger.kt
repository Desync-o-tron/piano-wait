package com.lukeknoble.freemidiplayer.telemetry

import android.content.Context
import com.lukeknoble.freemidiplayer.engine.PracticeStats
import com.lukeknoble.freemidiplayer.midi.MidiNote
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * Records step-level microphone diagnostics and (when the user opts in) uploads anonymized
 * JSON reports and short 16kHz 16-bit mono WAV snippets to gs://luke-piano-telemetry.
 */
class PracticeTelemetryLogger(
    context: Context,
    val songTitle: String,
    var bucket: String = DEFAULT_TELEMETRY_BUCKET
) {
    private val appContext = context.applicationContext
    private val startedAtIso: String
    val sessionId: String
    private val diagnostics = mutableListOf<JSONObject>()
    private var lastUploadCount = 0
    private var uploadedAudioCount = 0

    @Volatile
    var isOtaEnabled: Boolean = true

    @Volatile
    var isAudioUploadEnabled: Boolean = true

    @Volatile
    var flushStepInterval: Int = 5

    init {
        val now = Date()
        startedAtIso = formatIso8601(now)
        val safeSong = songTitle.lowercase(Locale.US)
            .replace(" ", "_")
            .filter { it.isLetterOrDigit() || it == '_' }
        val shortUuid = UUID.randomUUID().toString().take(6)
        sessionId = "${now.time / 1000}_${safeSong}_$shortUuid"
    }

    @Synchronized
    fun recordStep(
        stepIndex: Int,
        songTimeSeconds: Double,
        waitedSeconds: Double,
        outcome: String,
        expectedNotes: Set<Int>,
        latchedNotes: Set<Int>,
        heardNotes: Set<Int>,
        peakRms: Float,
        audioSnippetObjectName: String? = null
    ) {
        val missing = expectedNotes.minus(latchedNotes)
        val obj = JSONObject().apply {
            put("stepIndex", stepIndex)
            put("songTimeSeconds", songTimeSeconds)
            put("waitedSeconds", waitedSeconds)
            put("outcome", outcome)
            put("expectedNotes", JSONArray(expectedNotes.sorted().map { MidiNote.name(it) }))
            put("latchedNotes", JSONArray(latchedNotes.sorted().map { MidiNote.name(it) }))
            put("missingNotes", JSONArray(missing.sorted().map { MidiNote.name(it) }))
            put("heardNotesDuringStep", JSONArray(heardNotes.sorted().map { MidiNote.name(it) }))
            put("peakRMS", peakRms.toDouble())
            if (audioSnippetObjectName != null) {
                put("audioSnippetObjectName", audioSnippetObjectName)
            }
        }
        diagnostics.add(obj)
        if (diagnostics.size > 250) {
            diagnostics.removeAt(0)
        }
    }

    fun recordAndUploadAsync(
        stepIndex: Int,
        songTimeSeconds: Double,
        waitedSeconds: Double,
        outcome: String,
        expectedNotes: Set<Int>,
        latchedNotes: Set<Int>,
        heardNotes: Set<Int>,
        peakRms: Float,
        handSelection: String,
        stats: PracticeStats,
        audioSamples: ShortArray? = null,
        audioSampleRate: Int = 22_050
    ) {
        val optedIn = isUserOptedIn(appContext)
        Thread({
            var audioObjName: String? = null
            if (optedIn && isOtaEnabled && isAudioUploadEnabled && audioSamples != null && audioSamples.isNotEmpty() && uploadedAudioCount < 25) {
                val wavBytes = encodeMonoWav16kHz(audioSamples, audioSampleRate)
                if (wavBytes.isNotEmpty()) {
                    val candidateName = "audio/${sessionId}_step${stepIndex}_${outcome}_android.wav"
                    if (uploadMedia(candidateName, "audio/wav", wavBytes)) {
                        uploadedAudioCount += 1
                        audioObjName = candidateName
                    }
                }
            }

            recordStep(
                stepIndex = stepIndex,
                songTimeSeconds = songTimeSeconds,
                waitedSeconds = waitedSeconds,
                outcome = outcome,
                expectedNotes = expectedNotes,
                latchedNotes = latchedNotes,
                heardNotes = heardNotes,
                peakRms = peakRms,
                audioSnippetObjectName = audioObjName
            )

            uploadSnapshotSync(
                handSelection = handSelection,
                stats = stats,
                force = outcome == "skipped" || waitedSeconds >= 2.0
            )
        }, "PianoTelemetryUploadThread").apply {
            isDaemon = true
            start()
        }
    }

    @Synchronized
    fun uploadSnapshotSync(
        handSelection: String,
        stats: PracticeStats,
        force: Boolean = false
    ): Boolean {
        if (!force && diagnostics.size < lastUploadCount + flushStepInterval) return false
        if (diagnostics.isEmpty() && !force) return false
        lastUploadCount = diagnostics.size

        val report = JSONObject().apply {
            put("sessionId", sessionId)
            put("platform", "android")
            put("songTitle", songTitle)
            put("startedAtISO8601", startedAtIso)
            put("updatedAtISO8601", formatIso8601(Date()))
            put("handSelection", handSelection)
            put("stepsCompleted", stats.stepsCompleted)
            put("stepsSkipped", stats.stepsSkipped)
            put("wrongNotes", stats.wrongNotes)
            put("diagnostics", JSONArray(diagnostics))
        }

        val payload = report.toString(2).toByteArray(Charsets.UTF_8)
        try {
            val localDir = File(appContext.filesDir, "telemetry").apply { mkdirs() }
            File(localDir, "$sessionId.json").writeBytes(payload)
        } catch (_: Exception) {
        }

        if (!isUserOptedIn(appContext) || !isOtaEnabled || bucket.isBlank()) return true
        val objectName = "telemetry/${sessionId}_${diagnostics.size}_android.json"
        return uploadMedia(objectName, "application/json", payload)
    }

    private fun uploadMedia(objectName: String, contentType: String, payload: ByteArray): Boolean {
        val cleanBucket = bucket.trim()
        if (cleanBucket.isEmpty()) return false
        return try {
            val encodedName = URLEncoder.encode(objectName, "UTF-8")
            val url = URL("https://storage.googleapis.com/upload/storage/v1/b/$cleanBucket/o?uploadType=media&name=$encodedName")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 6000
                readTimeout = 6000
                setRequestProperty("Content-Type", contentType)
            }
            conn.outputStream.use { it.write(payload) }
            val ok = conn.responseCode in 200..299
            conn.disconnect()
            ok
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        const val DEFAULT_TELEMETRY_BUCKET = "luke-piano-telemetry"
        private const val PREFS_NAME = "pianowait_telemetry_prefs"
        private const val KEY_OPT_IN = "share_mic_telemetry_opt_in"
        private const val KEY_PROMPTED = "share_mic_telemetry_prompted"

        fun isUserOptedIn(context: Context): Boolean {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return prefs.getBoolean(KEY_OPT_IN, false)
        }

        fun setUserOptedIn(context: Context, optedIn: Boolean) {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit()
                .putBoolean(KEY_OPT_IN, optedIn)
                .putBoolean(KEY_PROMPTED, true)
                .apply()
        }

        fun hasPromptedUser(context: Context): Boolean {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return prefs.getBoolean(KEY_PROMPTED, false)
        }

        fun encodeMonoWav16kHz(samples: ShortArray, sourceSampleRate: Int): ByteArray {
            if (samples.isEmpty() || sourceSampleRate <= 0) return ByteArray(0)
            val targetRate = 16_000
            val ratio = sourceSampleRate.toDouble() / targetRate.toDouble()
            val outCount = (samples.size / ratio).toInt().coerceAtLeast(1)
            val dataSize = outCount * 2
            val out = ByteArrayOutputStream(44 + dataSize)

            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray(Charsets.US_ASCII))
            header.putInt(36 + dataSize)
            header.put("WAVE".toByteArray(Charsets.US_ASCII))
            header.put("fmt ".toByteArray(Charsets.US_ASCII))
            header.putInt(16) // PCM chunk size
            header.putShort(1) // PCM format
            header.putShort(1) // Mono
            header.putInt(targetRate)
            header.putInt(targetRate * 2)
            header.putShort(2) // BlockAlign
            header.putShort(16) // BitsPerSample
            header.put("data".toByteArray(Charsets.US_ASCII))
            header.putInt(dataSize)
            out.write(header.array())

            val pcmBuf = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until outCount) {
                val srcIdx = (i * ratio).toInt().coerceIn(0, samples.size - 1)
                pcmBuf.putShort(samples[srcIdx])
            }
            out.write(pcmBuf.array())
            return out.toByteArray()
        }

        private fun formatIso8601(date: Date): String {
            val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            sdf.timeZone = TimeZone.getTimeZone("UTC")
            return sdf.format(date)
        }
    }
}
