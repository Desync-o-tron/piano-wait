package com.lukeknoble.freemidiplayer.audio

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import com.lukeknoble.freemidiplayer.midi.MidiNote
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Connects USB / Bluetooth MIDI keyboards via Android MidiManager and optional acoustic
 * microphone pitch detection via AudioRecord.
 */
class HardwareMidiController(
    context: Context,
    private val onNoteOn: (pitch: Int, velocity: Int) -> Unit,
    private val onNoteOff: (pitch: Int) -> Unit,
    private val onMicNotesDetected: (Set<Int>) -> Unit,
    private val onDeviceStatusChanged: (String) -> Unit
) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val midiManager: MidiManager? =
        appContext.getSystemService(Context.MIDI_SERVICE) as? MidiManager

    private val openDevices = mutableMapOf<Int, MidiDevice>()
    private val openPorts = mutableListOf<MidiOutputPort>()
    private val micRunning = AtomicBoolean(false)
    private var micThread: Thread? = null

    private val deviceCallback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(device: MidiDeviceInfo) {
            connectMidiDevice(device)
            notifyStatus()
        }

        override fun onDeviceRemoved(device: MidiDeviceInfo) {
            val closed = openDevices.remove(device.id)
            try {
                closed?.close()
            } catch (_: Exception) {
            }
            notifyStatus()
        }
    }

    val isMicActive: Boolean
        get() = micRunning.get()

    val connectedMidiDeviceCount: Int
        get() = openDevices.size

    fun startMidiDiscovery() {
        val manager = midiManager ?: return
        manager.registerDeviceCallback(deviceCallback, mainHandler)
        for (info in manager.devices) {
            connectMidiDevice(info)
        }
        notifyStatus()
    }

    fun stopAll() {
        stopMicrophone()
        try {
            midiManager?.unregisterDeviceCallback(deviceCallback)
        } catch (_: Exception) {
        }
        for (port in openPorts) {
            try {
                port.close()
            } catch (_: Exception) {
            }
        }
        openPorts.clear()
        for (dev in openDevices.values) {
            try {
                dev.close()
            } catch (_: Exception) {
            }
        }
        openDevices.clear()
    }

    private fun connectMidiDevice(info: MidiDeviceInfo) {
        if (openDevices.containsKey(info.id)) return
        if (info.outputPortCount <= 0) return

        midiManager?.openDevice(info, { device ->
            if (device == null) return@openDevice
            openDevices[info.id] = device
            for (portIndex in 0 until info.outputPortCount) {
                val port = device.openOutputPort(portIndex) ?: continue
                port.connect(object : MidiReceiver() {
                    override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
                        parseMidiPacket(msg, offset, count)
                    }
                })
                openPorts.add(port)
            }
            notifyStatus()
        }, mainHandler)
    }

    private fun parseMidiPacket(msg: ByteArray, offset: Int, count: Int) {
        var i = offset
        val end = offset + count
        var runningStatus = 0
        while (i < end) {
            val b = msg[i].toInt() and 0xFF
            if (b >= 0xF0) {
                i += 1
                continue
            }
            val status: Int
            val d1: Int
            if ((b and 0x80) != 0) {
                status = b
                runningStatus = b
                if (i + 1 >= end) break
                d1 = msg[i + 1].toInt() and 0x7F
                i += 2
            } else {
                if (runningStatus == 0) {
                    i += 1
                    continue
                }
                status = runningStatus
                d1 = b and 0x7F
                i += 1
            }

            val kind = status and 0xF0
            if (kind == 0xC0 || kind == 0xD0) continue
            if (i >= end) break
            val d2 = msg[i].toInt() and 0x7F
            i += 1

            if (d1 in MidiNote.PIANO_RANGE) {
                if (kind == 0x90 && d2 > 0) {
                    mainHandler.post { onNoteOn(d1, d2) }
                } else if (kind == 0x80 || (kind == 0x90 && d2 == 0)) {
                    mainHandler.post { onNoteOff(d1) }
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun startMicrophone(): Boolean {
        if (!micRunning.compareAndSet(false, true)) return true
        val sampleRate = 22_050
        val frameSize = 2048
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuf <= 0) {
            micRunning.set(false)
            return false
        }

        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuf, frameSize * 4)
            )
        } catch (_: Exception) {
            micRunning.set(false)
            return false
        }

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            micRunning.set(false)
            return false
        }

        micThread = Thread({
            val shortBuf = ShortArray(frameSize)
            val floatBuf = FloatArray(frameSize)
            try {
                recorder.startRecording()
                while (micRunning.get()) {
                    val read = recorder.read(shortBuf, 0, frameSize)
                    if (read == frameSize) {
                        var energy = 0.0
                        for (idx in 0 until frameSize) {
                            val v = shortBuf[idx] / 32768f
                            floatBuf[idx] = v
                            energy += v * v
                        }
                        val rms = sqrt(energy / frameSize)
                        val detected = if (rms > 0.015) {
                            detectDominantNotes(floatBuf, sampleRate)
                        } else {
                            emptySet()
                        }
                        mainHandler.post { onMicNotesDetected(detected) }
                    }
                }
            } catch (_: Exception) {
            } finally {
                try {
                    recorder.stop()
                } catch (_: Exception) {
                }
                recorder.release()
                mainHandler.post { onMicNotesDetected(emptySet()) }
            }
        }, "PianoMicPitchThread").apply {
            isDaemon = true
            start()
        }
        notifyStatus()
        return true
    }

    fun stopMicrophone() {
        if (!micRunning.compareAndSet(true, false)) return
        micThread?.join(200)
        micThread = null
        notifyStatus()
    }

    /**
     * Normalized autocorrelation (YIN-inspired) fundamental pitch detector for acoustic piano notes.
     */
    private fun detectDominantNotes(samples: FloatArray, sampleRate: Int): Set<Int> {
        val n = samples.size
        val half = n / 2
        val minLag = (sampleRate / 1200.0).toInt().coerceAtLeast(4) // ~D6
        val maxLag = (sampleRate / 55.0).toInt().coerceAtMost(half - 1) // ~A1

        var bestLag = -1
        var bestCorr = 0.0
        for (lag in minLag..maxLag) {
            var sum = 0.0
            var e1 = 0.0
            var e2 = 0.0
            var i = 0
            while (i < half) {
                val a = samples[i].toDouble()
                val b = samples[i + lag].toDouble()
                sum += a * b
                e1 += a * a
                e2 += b * b
                i += 2
            }
            val denom = sqrt(e1 * e2)
            if (denom > 1e-6) {
                val corr = sum / denom
                if (corr > bestCorr) {
                    bestCorr = corr
                    bestLag = lag
                }
            }
        }
        if (bestLag <= 0 || bestCorr < 0.72) return emptySet()
        val freq = sampleRate.toDouble() / bestLag.toDouble()
        val midi = (69.0 + 12.0 * (ln(freq / 440.0) / ln(2.0))).roundToInt()
        return if (midi in MidiNote.PIANO_RANGE) setOf(midi) else emptySet()
    }

    private fun notifyStatus() {
        val parts = mutableListOf<String>()
        if (openDevices.isNotEmpty()) {
            parts.add("MIDI (${openDevices.size})")
        }
        if (micRunning.get()) {
            parts.add("Mic On")
        }
        val label = if (parts.isEmpty()) "Touch + Mic/MIDI" else parts.joinToString(" • ")
        mainHandler.post { onDeviceStatusChanged(label) }
    }
}
