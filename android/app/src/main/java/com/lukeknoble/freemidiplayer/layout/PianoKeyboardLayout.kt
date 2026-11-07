package com.lukeknoble.freemidiplayer.layout

import com.lukeknoble.freemidiplayer.midi.MidiNote
import com.lukeknoble.freemidiplayer.midi.MidiSong
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

class PianoKeyboardLayout(rawRange: IntRange = MidiNote.PIANO_RANGE) {
    data class KeyFrame(val x: Double, val width: Double)

    companion object {
        const val BLACK_KEY_WIDTH_RATIO: Double = 0.62
        const val BLACK_KEY_HEIGHT_RATIO: Double = 0.62
        private const val MINIMUM_AUTO_ZOOM_SEMITONES: Int = 24

        fun autoZoomed(song: MidiSong): PianoKeyboardLayout {
            val pitches = song.pitchRange ?: return PianoKeyboardLayout()
            var low = pitches.first - 2
            var high = pitches.last + 2
            val shortfall = MINIMUM_AUTO_ZOOM_SEMITONES - (high - low)
            if (shortfall > 0) {
                low -= shortfall / 2
                high += shortfall - shortfall / 2
            }
            val clampedLow = max(low, MidiNote.PIANO_RANGE.first)
            val clampedHigh = min(high, MidiNote.PIANO_RANGE.last)
            return PianoKeyboardLayout(clampedLow..clampedHigh)
        }
    }

    val range: IntRange
    private val whiteKeys: List<Int>
    private val whiteIndex: Map<Int, Int>

    init {
        var low = rawRange.first
        var high = rawRange.last
        if (MidiNote.isBlackKey(low) && low > 0) low -= 1
        if (MidiNote.isBlackKey(high) && high < 127) high += 1
        range = low..high
        whiteKeys = range.filter { !MidiNote.isBlackKey(it) }
        whiteIndex = whiteKeys.withIndex().associate { (idx, pitch) -> pitch to idx }
    }

    val whiteKeyCount: Int
        get() = whiteKeys.size

    val whiteKeyWidth: Double
        get() = 1.0 / whiteKeys.size.toDouble()

    fun frameFor(note: Int): KeyFrame? {
        if (note !in range) return null
        val wIdx = whiteIndex[note]
        if (wIdx != null) {
            return KeyFrame(x = wIdx.toDouble() * whiteKeyWidth, width = whiteKeyWidth)
        }
        val lowerWhite = whiteIndex[note - 1] ?: return null
        val width = whiteKeyWidth * BLACK_KEY_WIDTH_RATIO
        return KeyFrame(
            x = (lowerWhite + 1).toDouble() * whiteKeyWidth - width / 2.0,
            width = width
        )
    }

    fun noteAt(x: Double, y: Double): Int? {
        if (x < 0.0 || x >= 1.0) return null
        if (y < BLACK_KEY_HEIGHT_RATIO) {
            for (note in range) {
                if (MidiNote.isBlackKey(note)) {
                    val frame = frameFor(note) ?: continue
                    if (x >= frame.x && x < frame.x + frame.width) {
                        return note
                    }
                }
            }
        }
        val idx = (x / whiteKeyWidth).toInt().coerceIn(0, whiteKeys.lastIndex)
        return whiteKeys[idx]
    }
}

class PianoKeyboardViewport(
    val layout: PianoKeyboardLayout = PianoKeyboardLayout(),
    rawStart: Double = 0.0,
    rawWidth: Double = 1.0
) {
    companion object {
        const val MINIMUM_VISIBLE_WHITE_KEYS: Double = 7.0
        private const val TOLERANCE: Double = 1e-9

        fun fitting(
            range: IntRange,
            layout: PianoKeyboardLayout = PianoKeyboardLayout()
        ): PianoKeyboardViewport {
            val fitted = PianoKeyboardLayout(range).range
            val low = layout.frameFor(fitted.first)
            val high = layout.frameFor(fitted.last)
            if (low == null || high == null) {
                return PianoKeyboardViewport(layout = layout)
            }
            return PianoKeyboardViewport(
                layout = layout,
                rawStart = low.x,
                rawWidth = high.x + high.width - low.x
            )
        }
    }

    val width: Double
    val start: Double

    init {
        val minWidth = min(1.0, MINIMUM_VISIBLE_WHITE_KEYS * layout.whiteKeyWidth)
        width = rawWidth.coerceIn(minWidth, 1.0)
        start = rawStart.coerceIn(0.0, 1.0 - width)
    }

    val visibleNotes: IntRange
        get() {
            val visible = layout.range.filter { note ->
                val f = layout.frameFor(note) ?: return@filter false
                val center = f.x + f.width / 2.0
                center >= start && center <= start + width
            }
            val first = visible.firstOrNull() ?: return layout.range
            val last = visible.lastOrNull() ?: return layout.range
            return first..last
        }

    fun zoomed(factor: Double, anchor: Double = 0.5): PianoKeyboardViewport {
        if (factor <= 0.0 || !factor.isFinite()) return this
        val newWidth = width / factor
        return PianoKeyboardViewport(
            layout = layout,
            rawStart = start + anchor * width - anchor * newWidth,
            rawWidth = newWidth
        )
    }

    fun panned(amount: Double): PianoKeyboardViewport {
        return PianoKeyboardViewport(
            layout = layout,
            rawStart = start + amount * width,
            rawWidth = width
        )
    }

    fun isApproximatelyEqual(other: PianoKeyboardViewport): Boolean {
        return abs(start - other.start) < TOLERANCE && abs(width - other.width) < TOLERANCE
    }

    fun frameFor(note: Int): PianoKeyboardLayout.KeyFrame? {
        val frame = layout.frameFor(note) ?: return null
        val x = (frame.x - start) / width
        val keyWidth = frame.width / width
        if (x + keyWidth <= 0.0 || x >= 1.0) return null
        return PianoKeyboardLayout.KeyFrame(x = x, width = keyWidth)
    }

    fun noteAt(x: Double, y: Double): Int? {
        if (x < 0.0 || x >= 1.0) return null
        return layout.noteAt(start + x * width, y)
    }
}

class PracticeZoom(song: MidiSong) {
    companion object {
        val LOOKAHEAD_RANGE: ClosedFloatingPointRange<Double> = 2.0..8.0
        const val DEFAULT_LOOKAHEAD: Double = 4.0
        private const val ZOOM_STEP: Double = 1.25
        private const val PAN_STEP: Double = 0.25
    }

    private val songFit: PianoKeyboardViewport =
        PianoKeyboardViewport.fitting(PianoKeyboardLayout.autoZoomed(song).range)

    var keyboard: PianoKeyboardViewport = songFit
    var lookaheadSeconds: Double = DEFAULT_LOOKAHEAD
        set(value) {
            field = value.coerceIn(LOOKAHEAD_RANGE.start, LOOKAHEAD_RANGE.endInclusive)
        }

    fun zoomIn() {
        keyboard = keyboard.zoomed(ZOOM_STEP)
    }

    fun zoomOut() {
        keyboard = keyboard.zoomed(1.0 / ZOOM_STEP)
    }

    fun panLeft() {
        keyboard = keyboard.panned(-PAN_STEP)
    }

    fun panRight() {
        keyboard = keyboard.panned(PAN_STEP)
    }

    fun fitSong() {
        keyboard = songFit
    }

    fun showAllKeys() {
        keyboard = PianoKeyboardViewport(layout = keyboard.layout)
    }

    fun fallPosition(timeSeconds: Double, playhead: Double): Double {
        return (timeSeconds - playhead) / lookaheadSeconds
    }
}
