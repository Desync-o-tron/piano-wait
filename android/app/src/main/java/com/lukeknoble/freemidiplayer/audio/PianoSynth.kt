package com.lukeknoble.freemidiplayer.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * Low-latency Android AudioTrack synthesizer streaming 16-voice additive piano audio.
 */
class PianoSynth(private val sampleRate: Int = 44_100) {
    private val bank = PianoVoiceBank(sampleRate.toDouble())
    private val bankLock = Any()
    private val running = AtomicBoolean(false)
    private var audioThread: Thread? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return

        audioThread = Thread({
            val frameChunk = 256
            val minBufferBytes = AudioTrack.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_FLOAT
            )
            val bufferSizeInBytes = max(minBufferBytes, frameChunk * 4 * 4)

            val track = try {
                AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_GAME)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                            .setSampleRate(sampleRate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSizeInBytes)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                    .build()
            } catch (_: Exception) {
                null
            } ?: return@Thread

            val floatBuffer = FloatArray(frameChunk)
            try {
                track.play()
                while (running.get()) {
                    synchronized(bankLock) {
                        bank.render(floatBuffer, frameChunk)
                    }
                    track.write(floatBuffer, 0, frameChunk, AudioTrack.WRITE_BLOCKING)
                }
            } catch (_: Exception) {
                // Ignore shutdown interruptions
            } finally {
                try {
                    track.stop()
                } catch (_: Exception) {
                }
                track.release()
            }
        }, "PianoSynthAudioThread").apply {
            priority = Thread.MAX_PRIORITY
            isDaemon = true
            start()
        }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        synchronized(bankLock) {
            bank.allNotesOff()
        }
        audioThread?.join(300)
        audioThread = null
    }

    fun noteOn(note: Int, velocity: Int = 90, durationSeconds: Double? = null) {
        synchronized(bankLock) {
            bank.noteOn(note, velocity, durationSeconds)
        }
    }

    fun noteOff(note: Int) {
        synchronized(bankLock) {
            bank.noteOff(note)
        }
    }

    fun allNotesOff() {
        synchronized(bankLock) {
            bank.allNotesOff()
        }
    }
}
