package com.lukeknoble.freemidiplayer.config

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.lukeknoble.freemidiplayer.engine.WaitModeEngine
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

data class OTAConfig(
    val version: Int = 1,
    val updatedAt: String? = null,
    val rollWindow: Double? = null,
    val earlyGrace: Double? = null,
    val strikeMemorySeconds: Double? = null,
    val continuousWindow: Double? = null,
    val synthEchoSuppression: Double? = null,
    val partialChordGraceSeconds: Double? = null,
    val highlightLeadTimeSeconds: Double? = null,
    val autoPanKeyboardToExpectedNotes: Boolean? = null,
    val showUpcomingStepHighlight: Boolean? = null,
    val telemetryEnabled: Boolean? = null,
    val telemetryFlushStepInterval: Int? = null,
    val telemetryUploadAudioSnippets: Boolean? = null,
    val telemetryBucket: String? = null
) {
    fun applyTo(config: WaitModeEngine.Configuration) {
        rollWindow?.let { config.rollWindow = it }
        earlyGrace?.let { config.earlyGrace = it }
        strikeMemorySeconds?.let { config.strikeMemorySeconds = it }
        continuousWindow?.let { config.continuousWindow = it }
        synthEchoSuppression?.let { config.synthEchoSuppression = it }
        partialChordGraceSeconds?.let { config.partialChordGraceSeconds = it }
        highlightLeadTimeSeconds?.let { config.highlightLeadTimeSeconds = it }
    }

    companion object {
        fun parse(jsonText: String): OTAConfig {
            val root = JSONObject(jsonText)
            val engine = root.optJSONObject("engine")
            val ui = root.optJSONObject("ui")
            val telemetry = root.optJSONObject("telemetry")
            return OTAConfig(
                version = root.optInt("version", 1),
                updatedAt = if (root.has("updatedAt") && !root.isNull("updatedAt")) root.optString("updatedAt") else null,
                rollWindow = engine.optNullableDouble("rollWindow"),
                earlyGrace = engine.optNullableDouble("earlyGrace"),
                strikeMemorySeconds = engine.optNullableDouble("strikeMemorySeconds"),
                continuousWindow = engine.optNullableDouble("continuousWindow"),
                synthEchoSuppression = engine.optNullableDouble("synthEchoSuppression"),
                partialChordGraceSeconds = engine.optNullableDouble("partialChordGraceSeconds"),
                highlightLeadTimeSeconds = engine.optNullableDouble("highlightLeadTimeSeconds"),
                autoPanKeyboardToExpectedNotes = ui.optNullableBoolean("autoPanKeyboardToExpectedNotes"),
                showUpcomingStepHighlight = ui.optNullableBoolean("showUpcomingStepHighlight"),
                telemetryEnabled = telemetry.optNullableBoolean("enabled"),
                telemetryFlushStepInterval = if (telemetry != null && telemetry.has("flushStepInterval") && !telemetry.isNull("flushStepInterval")) telemetry.optInt("flushStepInterval") else null,
                telemetryUploadAudioSnippets = telemetry.optNullableBoolean("uploadAudioSnippets"),
                telemetryBucket = if (telemetry != null && telemetry.has("telemetryBucket") && !telemetry.isNull("telemetryBucket")) telemetry.optString("telemetryBucket") else null
            )
        }

        private fun JSONObject?.optNullableDouble(key: String): Double? {
            if (this == null || !has(key) || isNull(key)) return null
            val v = optDouble(key, Double.NaN)
            return if (v.isFinite()) v else null
        }

        private fun JSONObject?.optNullableBoolean(key: String): Boolean? {
            if (this == null || !has(key) || isNull(key)) return null
            return optBoolean(key)
        }
    }
}

object RemoteConfigLoader {
    private const val OTA_URL =
        "https://storage.googleapis.com/storage/v1/b/luke-piano-midis/o/config%2Fota-config.json?alt=media"
    private const val CACHE_FILE = "ota-config.json"

    @Volatile
    var latest: OTAConfig = OTAConfig()
        private set

    fun refreshAsync(context: Context, onLoaded: (OTAConfig) -> Unit) {
        val appContext = context.applicationContext
        val mainHandler = Handler(Looper.getMainLooper())
        Thread({
            val cacheFile = File(appContext.filesDir, CACHE_FILE)
            var loaded: OTAConfig? = null
            try {
                val conn = (URL(OTA_URL).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 5000
                    readTimeout = 5000
                    useCaches = false
                }
                if (conn.responseCode in 200..299) {
                    val body = conn.inputStream.bufferedReader().use { it.readText() }
                    loaded = OTAConfig.parse(body)
                    cacheFile.writeText(body)
                }
                conn.disconnect()
            } catch (_: Exception) {
            }

            if (loaded == null && cacheFile.exists()) {
                try {
                    loaded = OTAConfig.parse(cacheFile.readText())
                } catch (_: Exception) {
                }
            }

            val result = loaded ?: latest
            latest = result
            mainHandler.post { onLoaded(result) }
        }, "PianoWaitOTAConfigThread").apply {
            isDaemon = true
            start()
        }
    }
}
