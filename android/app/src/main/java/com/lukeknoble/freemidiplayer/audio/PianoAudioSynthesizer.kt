package com.lukeknoble.freemidiplayer.audio

import com.lukeknoble.freemidiplayer.midi.MidiNote
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Additive physical-modeling piano tone generator (fundamental + 6 stiff-string harmonics).
 */
object PianoAudioSynthesizer {
    data class Partial(
        val frequency: Double,
        val amplitude: Double,
        val fastDecay: Double,
        val slowDecay: Double
    )

    const val PARTIAL_COUNT: Int = 7
    const val ATTACK_SECONDS: Double = 0.004

    fun partials(
        note: Int,
        velocity: Int = 90,
        inharmonicityScale: Double = 0.8,
        detuneCents: Double = 0.0,
        a4: Double = 440.0
    ): List<Partial> {
        val fundamental = MidiNote.frequency(note, a4) * 2.0.pow(detuneCents / 1200.0)
        val clampedVel = velocity.coerceIn(1, 127)
        val loudness = (clampedVel.toDouble() / 127.0).pow(1.5)
        val inharmonicity = stringInharmonicity(note) * inharmonicityScale
        val normalization = sqrt(1.0 + inharmonicity)
        val rolloff = 1.45 - 0.45 * clampedVel.toDouble() / 127.0

        return (1..PARTIAL_COUNT).map { number ->
            val k = number.toDouble()
            var amplitude = loudness / k.pow(rolloff)
            if (number == 1 && fundamental < 110.0) {
                amplitude *= 0.35 + 0.65 * max(0.0, fundamental - 40.0) / 70.0
            }
            val slowDecay = min(6.0, 3.0 * (261.6 / fundamental).pow(0.5)) / k.pow(0.5)
            Partial(
                frequency = k * fundamental * sqrt(1.0 + inharmonicity * k * k) / normalization,
                amplitude = amplitude,
                fastDecay = slowDecay * 0.15,
                slowDecay = slowDecay
            )
        }
    }

    fun stringInharmonicity(note: Int): Double {
        return max(0.00015, 0.0004 * 10.0.pow((note.toDouble() - 60.0) / 30.0))
    }
}

/**
 * 16-voice polyphonic additive piano voice bank with zero allocation during audio rendering.
 */
class PianoVoiceBank(private val sampleRate: Double = 44_100.0) {
    companion object {
        const val VOICE_COUNT: Int = 16
        private const val RELEASE_SECONDS: Double = 0.12
        private const val SILENCE_THRESHOLD: Double = 0.00005
        private const val OUTPUT_GAIN: Double = 0.28
        private const val TWO_PI: Double = Math.PI * 2.0
    }

    private class Oscillator {
        var phase: Double = 0.0
        var phaseStep: Double = 0.0
        var fast: Double = 0.0
        var slow: Double = 0.0
        var fastStep: Double = 1.0
        var slowStep: Double = 1.0
    }

    private class Voice {
        var note: Int = 0
        var isActive: Boolean = false
        var isReleased: Boolean = false
        var framesUntilRelease: Int = Int.MAX_VALUE
        var attack: Double = 1.0
        var damper: Double = 1.0
        var age: Int = 0
    }

    private val attackStep: Double = 1.0 / max(1.0, PianoAudioSynthesizer.ATTACK_SECONDS * sampleRate)
    private val damperStep: Double = exp(-1.0 / (RELEASE_SECONDS * sampleRate))
    private val voices = Array(VOICE_COUNT) { Voice() }
    private val oscillators = Array(VOICE_COUNT * PianoAudioSynthesizer.PARTIAL_COUNT) { Oscillator() }

    val activeVoiceCount: Int
        get() = voices.count { it.isActive }

    fun noteOn(note: Int, velocity: Int = 90, durationSeconds: Double? = null) {
        val index = voices.indexOfFirst { !it.isActive }.let { if (it >= 0) it else oldestVoiceIndex() }
        val voice = voices[index]
        voice.note = note
        voice.isActive = true
        voice.isReleased = false
        voice.attack = 0.0
        voice.damper = 1.0
        voice.age = 0
        voice.framesUntilRelease = if (durationSeconds != null) {
            max(1, (durationSeconds * sampleRate).toInt())
        } else {
            Int.MAX_VALUE
        }

        val base = index * PianoAudioSynthesizer.PARTIAL_COUNT
        val partials = PianoAudioSynthesizer.partials(
            note = note,
            velocity = velocity,
            inharmonicityScale = 1.0
        )
        for ((offset, partial) in partials.withIndex()) {
            val isAudible = partial.frequency < sampleRate / 2.0
            val osc = oscillators[base + offset]
            osc.phase = 0.0
            osc.phaseStep = TWO_PI * partial.frequency / sampleRate
            osc.fast = if (isAudible) partial.amplitude * 0.6 else 0.0
            osc.slow = if (isAudible) partial.amplitude * 0.4 else 0.0
            osc.fastStep = exp(-1.0 / (partial.fastDecay * sampleRate))
            osc.slowStep = exp(-1.0 / (partial.slowDecay * sampleRate))
        }
    }

    fun noteOff(note: Int) {
        for (voice in voices) {
            if (voice.isActive && voice.note == note) {
                voice.isReleased = true
            }
        }
    }

    fun allNotesOff() {
        for (voice in voices) {
            if (voice.isActive) {
                voice.isReleased = true
            }
        }
    }

    fun render(buffer: FloatArray, frameCount: Int) {
        for (i in 0 until frameCount) {
            buffer[i] = 0f
        }

        for (voiceIndex in voices.indices) {
            val voice = voices[voiceIndex]
            if (!voice.isActive) continue

            val base = voiceIndex * PianoAudioSynthesizer.PARTIAL_COUNT
            var loudest = 0.0

            for (frame in 0 until frameCount) {
                if (voice.framesUntilRelease == 0) {
                    voice.isReleased = true
                }
                if (voice.framesUntilRelease != Int.MAX_VALUE) {
                    voice.framesUntilRelease -= 1
                }
                if (voice.isReleased) {
                    voice.damper *= damperStep
                }
                voice.attack = min(1.0, voice.attack + attackStep)

                var sample = 0.0
                for (p in base until (base + PianoAudioSynthesizer.PARTIAL_COUNT)) {
                    val osc = oscillators[p]
                    val level = osc.fast + osc.slow
                    sample += level * sin(osc.phase)
                    osc.phase += osc.phaseStep
                    if (osc.phase > TWO_PI) osc.phase -= TWO_PI
                    osc.fast *= osc.fastStep
                    osc.slow *= osc.slowStep
                }
                val gain = voice.attack * voice.damper
                buffer[frame] += (sample * gain * OUTPUT_GAIN).toFloat()
                if (gain > loudest) loudest = gain
            }

            voice.age += frameCount
            val remaining = oscillators[base].slow + oscillators[base + 1].slow
            if (voice.damper * remaining < SILENCE_THRESHOLD || loudest < SILENCE_THRESHOLD) {
                voice.isActive = false
            }
        }
    }

    private fun oldestVoiceIndex(): Int {
        var oldest = 0
        for (i in voices.indices) {
            if (voices[i].age > voices[oldest].age) {
                oldest = i
            }
        }
        return oldest
    }
}
