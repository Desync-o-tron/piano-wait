package com.lukeknoble.freemidiplayer.midi

import com.lukeknoble.freemidiplayer.engine.HandSelection

enum class Hand {
    LEFT,
    RIGHT
}

data class SongNote(
    val pitch: Int,
    val velocity: Int,
    val startTick: Int,
    val startSeconds: Double,
    val endSeconds: Double,
    val track: Int,
    val channel: Int,
    val hand: Hand
) {
    val durationSeconds: Double
        get() = (endSeconds - startSeconds).coerceAtLeast(0.05)
}

data class ChordStep(
    val index: Int,
    val timeSeconds: Double,
    val notes: List<SongNote>
) {
    val pitches: Set<Int> = notes.mapTo(linkedSetOf()) { it.pitch }

    fun pitches(selection: HandSelection): Set<Int> {
        return notes.asSequence()
            .filter { selection.includes(it.hand) }
            .mapTo(linkedSetOf()) { it.pitch }
    }
}

data class TempoEvent(
    val tick: Int,
    val microsecondsPerQuarter: Int,
    val seconds: Double
) {
    val beatsPerMinute: Double
        get() = 60_000_000.0 / microsecondsPerQuarter.toDouble()
}

data class TimeSignatureEvent(
    val tick: Int,
    val numerator: Int,
    val denominator: Int,
    val seconds: Double
)

data class MidiSong(
    val title: String,
    val composer: String = "",
    val format: Int,
    val trackNames: List<String>,
    val tempoEvents: List<TempoEvent>,
    val timeSignatures: List<TimeSignatureEvent>,
    val notes: List<SongNote>,
    val steps: List<ChordStep>,
    val durationSeconds: Double,
    val barStartSeconds: List<Double>,
    val droppedNoteCount: Int
) {
    val noteCount: Int
        get() = notes.size

    val pitchRange: IntRange?
        get() {
            if (notes.isEmpty()) return null
            var minPitch = Int.MAX_VALUE
            var maxPitch = Int.MIN_VALUE
            for (n in notes) {
                if (n.pitch < minPitch) minPitch = n.pitch
                if (n.pitch > maxPitch) maxPitch = n.pitch
            }
            return minPitch..maxPitch
        }
}

data class LibrarySongItem(
    val id: String,
    val title: String,
    val composer: String,
    val assetFileName: String? = null,
    val localFilePath: String? = null,
    val isBuiltIn: Boolean = true
)
