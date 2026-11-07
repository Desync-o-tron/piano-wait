package com.lukeknoble.freemidiplayer.midi

import kotlin.math.pow

/**
 * Helpers for MIDI note numbers on the 88-key piano (A0 = 21 ... C8 = 108).
 */
object MidiNote {
    val PIANO_RANGE: IntRange = 21..108
    const val MIDDLE_C: Int = 60

    private val SHARP_NAMES = arrayOf("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")

    fun frequency(note: Int, a4: Double = 440.0): Double {
        return a4 * 2.0.pow((note - 69).toDouble() / 12.0)
    }

    fun name(note: Int): String {
        val clamped = note.coerceIn(0, 127)
        val pitchClass = clamped % 12
        val octave = clamped / 12 - 1
        return "${SHARP_NAMES[pitchClass]}$octave"
    }

    fun isBlackKey(note: Int): Boolean {
        return when (note % 12) {
            1, 3, 6, 8, 10 -> true
            else -> false
        }
    }

    fun parse(text: String): Int? {
        val trimmed = text.trim()
        if (trimmed.length < 2) return null
        val base = when (trimmed[0]) {
            'C' -> 0
            'D' -> 2
            'E' -> 4
            'F' -> 5
            'G' -> 7
            'A' -> 9
            'B' -> 11
            else -> return null
        }
        var index = 1
        var semitone = base
        if (index < trimmed.length && trimmed[index] == '#') {
            semitone += 1
            index += 1
        } else if (index < trimmed.length && trimmed[index] == 'b') {
            semitone -= 1
            index += 1
        }
        val octave = trimmed.substring(index).toIntOrNull() ?: return null
        val value = (octave + 1) * 12 + semitone
        return if (value in 0..127) value else null
    }
}
