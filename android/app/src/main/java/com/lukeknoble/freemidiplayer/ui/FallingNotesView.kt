package com.lukeknoble.freemidiplayer.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import com.lukeknoble.freemidiplayer.engine.HandSelection
import com.lukeknoble.freemidiplayer.engine.PlaybackState
import com.lukeknoble.freemidiplayer.engine.WaitModeEngine
import com.lukeknoble.freemidiplayer.layout.PracticeZoom
import com.lukeknoble.freemidiplayer.midi.Hand
import com.lukeknoble.freemidiplayer.midi.MidiNote
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * 60fps falling-notes canvas colored by hand, with glow on active waiting chord notes
 * and pinch-to-zoom / horizontal drag-to-pan.
 */
class FallingNotesView(
    context: Context,
    private val engine: WaitModeEngine,
    private val zoom: PracticeZoom,
    private val onViewportChanged: () -> Unit
) : View(context) {

    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val lanePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val loopPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(32, 255, 204, 56)
    }
    private val noteFillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val noteStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
    }
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val hitLinePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()

    var loopStartSeconds: Double? = null
    var loopEndSeconds: Double? = null

    private var lastTouchX = 0f
    private var isDragging = false
    private var isScaling = false

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                isScaling = true
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

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (h > 0) {
            bgPaint.shader = LinearGradient(
                0f, 0f, 0f, h.toFloat(),
                Color.rgb(15, 20, 36),
                Color.rgb(10, 13, 23),
                Shader.TileMode.CLAMP
            )
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastTouchX = event.x
                isDragging = false
            }
            MotionEvent.ACTION_MOVE -> {
                if (!isScaling && event.pointerCount == 1 && width > 0) {
                    val dx = event.x - lastTouchX
                    if (isDragging || abs(dx) > 8f) {
                        isDragging = true
                        lastTouchX = event.x
                        zoom.keyboard = zoom.keyboard.panned((-dx / width.toDouble()))
                        onViewportChanged()
                        invalidate()
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                isDragging = false
            }
        }
        return true
    }

    private fun yForTime(time: Double, h: Float): Float {
        val frac = zoom.fallPosition(time, engine.playhead).toFloat()
        return h - frac * h
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return

        // 1. Backdrop
        canvas.drawRect(0f, 0f, w, h, bgPaint)

        // 2. Key lanes and octave lines
        val kb = zoom.keyboard
        for (note in kb.layout.range) {
            val frame = kb.frameFor(note) ?: continue
            val x = (frame.x * w).toFloat()
            val kw = (frame.width * w).toFloat()
            when {
                MidiNote.isBlackKey(note) -> {
                    lanePaint.color = Color.argb(6, 255, 255, 255)
                    canvas.drawRect(x, 0f, x + kw, h, lanePaint)
                }
                note % 12 == 0 -> {
                    lanePaint.color = Color.argb(28, 255, 255, 255)
                    canvas.drawRect(x, 0f, x + 2f, h, lanePaint)
                }
                note % 12 == 5 -> {
                    lanePaint.color = Color.argb(14, 255, 255, 255)
                    canvas.drawRect(x, 0f, x + 1f, h, lanePaint)
                }
            }
        }

        // 3. A-B Loop band
        val ls = loopStartSeconds
        if (ls != null) {
            val bottom = yForTime(ls, h)
            val top = loopEndSeconds?.let { yForTime(it, h) } ?: (bottom - 4f)
            canvas.drawRect(0f, min(top, bottom), w, max(top + 4f, bottom), loopPaint)
        }

        // 4. Falling notes
        val windowEnd = engine.playhead + zoom.lookaheadSeconds
        val selection = engine.handSelection
        val latched = engine.latched

        for (step in engine.song.steps) {
            if (step.timeSeconds > windowEnd) break
            val isCurrent = engine.state == PlaybackState.WAITING &&
                abs(step.timeSeconds - engine.playhead) < 0.001

            for (note in step.notes) {
                if (note.endSeconds < engine.playhead) continue
                val frame = kb.frameFor(note.pitch) ?: continue

                val top = yForTime(note.endSeconds, h)
                val bottom = yForTime(note.startSeconds, h)
                val left = (frame.x * w).toFloat() + 2f
                val noteW = max(5f, (frame.width * w).toFloat() - 4f)
                val noteH = max(10f, bottom - top)
                rect.set(left, bottom - noteH, left + noteW, bottom)

                val isLeft = note.hand == Hand.LEFT
                val isActiveHand = selection.includes(note.hand)
                val alpha = if (isActiveHand) 245 else 72

                val fillColor = if (isLeft) {
                    Color.argb(alpha, 56, 143, 250)
                } else {
                    Color.argb(alpha, 26, 209, 148)
                }

                val corner = min(10f, noteW / 2.6f)
                val isLatched = isCurrent && latched.contains(note.pitch)

                if (isCurrent && isActiveHand) {
                    val glowColor = if (isLatched) {
                        Color.argb(120, 46, 242, 173)
                    } else {
                        Color.argb(120, 255, 204, 56)
                    }
                    glowPaint.color = glowColor
                    canvas.drawRoundRect(
                        rect.left - 4f,
                        rect.top - 4f,
                        rect.right + 4f,
                        rect.bottom + 4f,
                        corner + 4f,
                        corner + 4f,
                        glowPaint
                    )
                }

                noteFillPaint.color = fillColor
                canvas.drawRoundRect(rect, corner, corner, noteFillPaint)

                if (isCurrent && isActiveHand) {
                    noteStrokePaint.strokeWidth = 3f
                    noteStrokePaint.color = if (isLatched) {
                        Color.rgb(46, 242, 173)
                    } else {
                        Color.rgb(255, 204, 56)
                    }
                } else {
                    noteStrokePaint.strokeWidth = 1.5f
                    noteStrokePaint.color = Color.argb(if (isActiveHand) 64 else 24, 255, 255, 255)
                }
                canvas.drawRoundRect(rect, corner, corner, noteStrokePaint)
            }
        }

        // 5. Hit line at keyboard boundary
        hitLinePaint.color = if (engine.state == PlaybackState.WAITING) {
            Color.rgb(255, 204, 56)
        } else {
            Color.argb(180, 26, 209, 148)
        }
        canvas.drawRect(0f, h - 5f, w, h, hitLinePaint)
    }
}
