package com.lukeknoble.freemidiplayer.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import com.lukeknoble.freemidiplayer.engine.WaitModeEngine
import com.lukeknoble.freemidiplayer.layout.PianoKeyboardLayout
import com.lukeknoble.freemidiplayer.layout.PracticeZoom
import com.lukeknoble.freemidiplayer.midi.MidiNote
import kotlin.math.min

/**
 * Interactive 88-key touch piano showing expected keys, latched chord notes,
 * active multi-touch presses, microphone-heard notes, and pinch-to-zoom.
 */
class PianoKeyboardView(
    context: Context,
    private val engine: WaitModeEngine,
    private val zoom: PracticeZoom,
    private val onKeyPressed: (Int) -> Unit,
    private val onKeyReleased: (Int) -> Unit,
    private val onViewportChanged: () -> Unit
) : View(context) {

    private val keyPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(140, 20, 24, 34)
        textAlign = Paint.Align.CENTER
        textSize = 24f
        isFakeBoldText = true
    }
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(245, 97, 199)
    }
    private val rect = RectF()

    val pressedKeys = mutableSetOf<Int>()
    var heardNotes: Set<Int> = emptySet()

    private val pointerToNote = mutableMapOf<Int, Int>()
    private var isScaling = false

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                isScaling = true
                releaseAllPointers()
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                if (width <= 0) return false
                val anchor = (detector.focusX / width.toDouble()).coerceIn(0.0, 1.0)
                zoom.keyboard = zoom.keyboard.zoomed(detector.scaleFactor.toDouble(), anchor)
                onViewportChanged()
                invalidate()
                return true
            }

            override fun onScaleEnd(detector: ScaleGestureDetector) {
                isScaling = false
            }
        }
    )

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        if (isScaling || width <= 0 || height <= 0) {
            return true
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val idx = event.actionIndex
                val pointerId = event.getPointerId(idx)
                val note = noteAtTouch(event.getX(idx), event.getY(idx))
                if (note != null) {
                    pointerToNote[pointerId] = note
                    if (pressedKeys.add(note)) {
                        onKeyPressed(note)
                    }
                    invalidate()
                }
            }
            MotionEvent.ACTION_MOVE -> {
                var changed = false
                for (i in 0 until event.pointerCount) {
                    val pointerId = event.getPointerId(i)
                    val newNote = noteAtTouch(event.getX(i), event.getY(i))
                    val oldNote = pointerToNote[pointerId]
                    if (newNote != oldNote) {
                        if (oldNote != null) {
                            pointerToNote.remove(pointerId)
                            if (!pointerToNote.containsValue(oldNote)) {
                                pressedKeys.remove(oldNote)
                                onKeyReleased(oldNote)
                            }
                        }
                        if (newNote != null) {
                            pointerToNote[pointerId] = newNote
                            if (pressedKeys.add(newNote)) {
                                onKeyPressed(newNote)
                            }
                        }
                        changed = true
                    }
                }
                if (changed) invalidate()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val idx = event.actionIndex
                val pointerId = event.getPointerId(idx)
                val oldNote = pointerToNote.remove(pointerId)
                if (oldNote != null && !pointerToNote.containsValue(oldNote)) {
                    pressedKeys.remove(oldNote)
                    onKeyReleased(oldNote)
                    invalidate()
                }
            }
            MotionEvent.ACTION_CANCEL -> {
                releaseAllPointers()
                invalidate()
            }
        }
        return true
    }

    private fun releaseAllPointers() {
        val active = pointerToNote.values.toSet()
        pointerToNote.clear()
        for (note in active) {
            if (pressedKeys.remove(note)) {
                onKeyReleased(note)
            }
        }
    }

    private fun noteAtTouch(px: Float, py: Float): Int? {
        val nx = (px / width.toDouble()).coerceIn(0.0, 0.999999)
        val ny = (py / height.toDouble()).coerceIn(0.0, 0.999999)
        return zoom.keyboard.noteAt(nx, ny)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return

        val notes = zoom.keyboard.layout.range
        val waiting = if (engine.waitingNotes.isNotEmpty()) engine.waitingNotes else engine.upcomingNotes
        val latched = engine.latched

        // Draw white keys first, then black keys on top
        for (note in notes) {
            if (!MidiNote.isBlackKey(note)) {
                drawKey(canvas, note, isBlack = false, w = w, h = h, waiting = waiting, latched = latched)
            }
        }
        for (note in notes) {
            if (MidiNote.isBlackKey(note)) {
                drawKey(canvas, note, isBlack = true, w = w, h = h, waiting = waiting, latched = latched)
            }
        }
    }

    private fun drawKey(
        canvas: Canvas,
        note: Int,
        isBlack: Boolean,
        w: Float,
        h: Float,
        waiting: Set<Int>,
        latched: Set<Int>
    ) {
        val frame = zoom.keyboard.frameFor(note) ?: return
        val keyH = if (isBlack) (h * PianoKeyboardLayout.BLACK_KEY_HEIGHT_RATIO).toFloat() else h
        val inset = if (isBlack) 0f else 1.2f
        val left = (frame.x * w).toFloat() + inset
        val right = ((frame.x + frame.width) * w).toFloat() - inset
        if (right <= left) return

        rect.set(left, 0f, right, keyH)
        val corner = min(if (isBlack) 9f else 11f, rect.width() / 3.2f)

        val isLatched = latched.contains(note)
        val isWaiting = waiting.contains(note)
        val isPressed = pressedKeys.contains(note)

        keyPaint.color = when {
            isLatched -> Color.rgb(46, 242, 173)
            isWaiting -> Color.rgb(255, 204, 56)
            isPressed -> if (isBlack) Color.rgb(72, 82, 108) else Color.rgb(195, 205, 225)
            isBlack -> Color.rgb(28, 32, 44)
            else -> Color.rgb(246, 248, 252)
        }
        canvas.drawRoundRect(rect, corner, corner, keyPaint)

        borderPaint.color = if (isBlack) {
            Color.argb(45, 255, 255, 255)
        } else {
            Color.argb(90, 0, 0, 0)
        }
        canvas.drawRoundRect(rect, corner, corner, borderPaint)

        if (!isBlack && note % 12 == 0 && rect.width() >= 28f) {
            labelPaint.textSize = min(26f, rect.width() * 0.42f)
            canvas.drawText(MidiNote.name(note), rect.centerX(), rect.bottom - 16f, labelPaint)
        }

        if (heardNotes.contains(note)) {
            val radius = min(rect.width() * 0.26f, 12f)
            val cy = rect.bottom - radius * 2f - (if (!isBlack && note % 12 == 0) 32f else 10f)
            canvas.drawCircle(rect.centerX(), cy, radius, dotPaint)
        }
    }
}
