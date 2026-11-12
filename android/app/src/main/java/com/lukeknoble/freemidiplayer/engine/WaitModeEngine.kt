package com.lukeknoble.freemidiplayer.engine

import com.lukeknoble.freemidiplayer.midi.MidiSong
import com.lukeknoble.freemidiplayer.midi.SongNote
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The practice state machine (Wait-for-Me & Continuous Play-Along modes).
 */
class WaitModeEngine(
    val song: MidiSong,
    mode: PlaybackMode = PlaybackMode.WAIT_FOR_ME,
    val configuration: Configuration = Configuration()
) {
    data class Configuration(
        var rollWindow: Double = 0.6,
        var strikeMemorySeconds: Double? = null,
        var earlyGrace: Double = 0.25,
        var continuousWindow: Double = 0.25,
        var leadIn: Double = 0.0,
        var synthEchoSuppression: Double = 1.0,
        var partialChordGraceSeconds: Double? = null,
        var highlightLeadTimeSeconds: Double = 1.5
    )

    companion object {
        val SPEED_RANGE: ClosedFloatingPointRange<Double> = 0.25..2.0
        val SPEED_PRESETS: List<Double> = listOf(0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0)
    }

    var playhead: Double = -configuration.leadIn
        private set
    var state: PlaybackState = PlaybackState.PAUSED
        private set
    var stats: PracticeStats = PracticeStats()
        private set
    val stepStatuses: MutableList<StepStatus> = MutableList(song.steps.size) { StepStatus.PENDING }
    var speed: Double = 1.0
        private set
    var mode: PlaybackMode = mode
        private set
    var handSelection: HandSelection = HandSelection.BOTH
        private set
    var loopRange: ClosedFloatingPointRange<Double>? = null
        private set

    var autoPlayAccompaniment: Boolean = true
    var playsReferenceAudio: Boolean = true

    private var cursor: Int = 0
    private var scoringCursor: Int = 0
    private var clock: Double = 0.0
    private val pendingEvents = mutableListOf<PracticeEvent>()
    private var previouslyHeard = emptySet<Int>()
    private var activeNotesAtStepStart = emptySet<Int>()
    private val armedNotes = mutableMapOf<Int, Double>()
    private val latchedNotes = mutableMapOf<Int, Double>()
    private val continuousHits = mutableMapOf<Int, MutableSet<Int>>()
    private val echoSuppressedUntil = mutableMapOf<Int, Double>()

    val isWaiting: Boolean
        get() = state == PlaybackState.WAITING

    val currentStepIndex: Int?
        get() = if (cursor < song.steps.size) cursor else null

    val waitingNotes: Set<Int>
        get() {
            if (state != PlaybackState.WAITING && !(state == PlaybackState.PAUSED && isAtCurrentStep)) {
                return emptySet()
            }
            return if (cursor < song.steps.size) expectedNotes(cursor) else emptySet()
        }

    val upcomingNotes: Set<Int>
        get() {
            if (state == PlaybackState.WAITING || (state == PlaybackState.PAUSED && isAtCurrentStep)) {
                return waitingNotes
            }
            if (state != PlaybackState.PLAYING && state != PlaybackState.PAUSED) {
                return emptySet()
            }
            val nextIdx = nextNonEmptyStepIndex(cursor) ?: return emptySet()
            val dt = song.steps[nextIdx].timeSeconds - playhead
            val leadTime = max(configuration.highlightLeadTimeSeconds, 0.25) * max(speed, 0.5)
            return if (dt <= leadTime) expectedNotes(nextIdx) else emptySet()
        }

    private fun nextNonEmptyStepIndex(startIndex: Int): Int? {
        var idx = max(0, startIndex)
        while (idx < song.steps.size) {
            if (expectedNotes(idx).isNotEmpty()) return idx
            idx += 1
        }
        return null
    }

    val latched: Set<Int>
        get() = latchedNotes.keys.toSet()

    val progress: Double
        get() {
            if (stepStatuses.isEmpty()) return 1.0
            val done = stepStatuses.count { it != StepStatus.PENDING }
            return done.toDouble() / stepStatuses.size.toDouble()
        }

    private val isAtCurrentStep: Boolean
        get() = cursor < song.steps.size && abs(song.steps[cursor].timeSeconds - playhead) < 1e-9

    private fun expectedNotes(stepIndex: Int): Set<Int> {
        return song.steps[stepIndex].pitches(handSelection)
    }

    fun play() {
        if (state != PlaybackState.PAUSED) return
        state = PlaybackState.PLAYING
        advance(0.0)
    }

    fun pause() {
        if (state == PlaybackState.PLAYING || state == PlaybackState.WAITING) {
            state = PlaybackState.PAUSED
        }
    }

    fun restart() {
        playhead = -configuration.leadIn
        for (i in stepStatuses.indices) {
            stepStatuses[i] = StepStatus.PENDING
        }
        stats = PracticeStats()
        cursor = 0
        scoringCursor = 0
        state = PlaybackState.PAUSED
        clearMatchState()
        pendingEvents.clear()
    }

    fun seek(seconds: Double) {
        val wasRunning = state == PlaybackState.PLAYING || state == PlaybackState.WAITING
        playhead = seconds.coerceIn(-configuration.leadIn, song.durationSeconds)
        cursor = firstStepIndexAtOrAfter(playhead)
        scoringCursor = firstStepIndexAtOrAfter(playhead - scoringWindow)
        for (i in scoringCursor until song.steps.size) {
            stepStatuses[i] = StepStatus.PENDING
        }
        clearMatchState()
        state = if (wasRunning) PlaybackState.PLAYING else PlaybackState.PAUSED
        if (wasRunning) advance(0.0)
    }

    fun tick(deltaTime: Double): List<PracticeEvent> {
        if (state == PlaybackState.PLAYING || state == PlaybackState.WAITING) {
            val dt = max(0.0, deltaTime)
            clock += dt
            expireLatches()
            if (state == PlaybackState.WAITING) {
                checkPartialChordGrace()
            }
            if (state == PlaybackState.PLAYING) {
                advance(dt * speed)
            }
        }
        return drainEvents()
    }

    fun drainEvents(): List<PracticeEvent> {
        if (pendingEvents.isEmpty()) return emptyList()
        val copy = pendingEvents.toList()
        pendingEvents.clear()
        return copy
    }

    fun updateSpeed(newSpeed: Double) {
        speed = newSpeed.coerceIn(SPEED_RANGE.start, SPEED_RANGE.endInclusive)
    }

    fun updateHandSelection(selection: HandSelection) {
        if (selection == handSelection) return
        handSelection = selection
        latchedNotes.clear()
        continuousHits.clear()
        if (state == PlaybackState.WAITING) {
            state = PlaybackState.PLAYING
            advance(0.0)
        }
    }

    fun updateMode(newMode: PlaybackMode) {
        if (newMode == mode) return
        mode = newMode
        latchedNotes.clear()
        continuousHits.clear()
        scoringCursor = cursor
        if (state == PlaybackState.WAITING) state = PlaybackState.PLAYING
        if (state == PlaybackState.PLAYING) advance(0.0)
    }

    fun setLoop(start: Double, end: Double): Boolean {
        val clampedStart = max(0.0, start)
        val clampedEnd = min(song.durationSeconds, end)
        if (clampedStart >= clampedEnd) return false
        loopRange = clampedStart..clampedEnd
        if (playhead < clampedStart || playhead >= clampedEnd) {
            seek(clampedStart)
        }
        return true
    }

    fun clearLoop() {
        loopRange = null
    }

    fun ingest(
        heard: Set<Int>,
        onsets: Set<Int> = emptySet(),
        unambiguous: Set<Int>? = null,
        matchedExpected: Set<Int> = emptySet()
    ) {
        if (state == PlaybackState.FINISHED) return

        var fresh = heard.minus(previouslyHeard).union(onsets.intersect(heard))
        if (mode == PlaybackMode.WAIT_FOR_ME && state == PlaybackState.WAITING && cursor < song.steps.size) {
            val expected = expectedNotes(cursor)
            if (expected.size >= 2 && latchedNotes.isNotEmpty()) {
                val chordPresent = matchedExpected.intersect(expected)
                    .minus(latchedNotes.keys)
                    .minus(activeNotesAtStepStart)
                fresh = fresh.union(chordPresent)
            }
        }
        fresh = fresh.filterTo(linkedSetOf()) { (echoSuppressedUntil[it] ?: Double.NEGATIVE_INFINITY) <= clock }
        previouslyHeard = heard
        activeNotesAtStepStart = activeNotesAtStepStart.intersect(heard)

        val toRemove = mutableListOf<Int>()
        for ((note, struckAt) in armedNotes) {
            if (!heard.contains(note)) {
                val mem = configuration.strikeMemorySeconds
                if (mem != null && clock - struckAt <= mem) continue
                toRemove.add(note)
            }
        }
        for (note in toRemove) armedNotes.remove(note)
        for (note in fresh) armedNotes[note] = clock

        if (state != PlaybackState.PLAYING && state != PlaybackState.WAITING) return
        expireLatches()
        val wrongCandidates = unambiguous?.let { fresh.intersect(it) } ?: fresh
        match(fresh, wrongCandidates)
    }

    fun registerKeyPress(pitch: Int) {
        if (state != PlaybackState.PLAYING && state != PlaybackState.WAITING) return
        armedNotes[pitch] = clock
        echoSuppressedUntil[pitch] = clock + configuration.synthEchoSuppression
        match(setOf(pitch), setOf(pitch))
    }

    fun skipStep() {
        if (mode != PlaybackMode.WAIT_FOR_ME || cursor >= song.steps.size || state == PlaybackState.FINISHED) return
        val index = cursor
        val expected = expectedNotes(index)
        val hit = expected.intersect(latchedNotes.keys).size
        stats.notesHit += hit
        stats.notesMissed += expected.size - hit
        stats.stepsSkipped += 1
        stats.currentStreak = 0
        stepStatuses[index] = StepStatus.SKIPPED

        playhead = max(playhead, song.steps[index].timeSeconds)
        emitAudio(index, forceAllNotes = true)
        finishCurrentStep()
    }

    private fun advance(songTime: Double) {
        var remaining = songTime
        while (state == PlaybackState.PLAYING) {
            var target = song.durationSeconds
            val loop = loopRange
            if (loop != null && playhead < loop.endInclusive) {
                target = min(target, loop.endInclusive)
            }
            if (cursor < song.steps.size) {
                target = min(target, song.steps[cursor].timeSeconds)
            }

            if (playhead + remaining < target) {
                playhead += remaining
                remaining = 0.0
                break
            }
            remaining -= max(0.0, target - playhead)
            playhead = max(playhead, target)

            if (loop != null && playhead >= loop.endInclusive) {
                jumpToLoopStart(loop)
            } else if (cursor < song.steps.size && song.steps[cursor].timeSeconds <= playhead) {
                arrive(cursor)
            } else {
                finish()
            }
        }
        if (mode == PlaybackMode.CONTINUOUS) {
            finalizePassedContinuousSteps()
        }
    }

    private fun arrive(index: Int) {
        val expected = expectedNotes(index)
        if (expected.isEmpty()) {
            stepStatuses[index] = StepStatus.AUTO_PASSED
            emitAudio(index)
            cursor += 1
            if (mode == PlaybackMode.CONTINUOUS) finalizePassedContinuousSteps()
            return
        }

        when (mode) {
            PlaybackMode.CONTINUOUS -> {
                emitAudio(index)
                cursor += 1
                finalizePassedContinuousSteps()
                consumeArmedNotes()
            }
            PlaybackMode.WAIT_FOR_ME -> {
                state = PlaybackState.WAITING
                latchedNotes.clear()
                activeNotesAtStepStart = previouslyHeard
                consumeArmedNotes()
            }
        }
    }

    private fun consumeArmedNotes() {
        val window = max(configuration.earlyGrace, configuration.strikeMemorySeconds ?: 0.0)
        val recent = armedNotes.filter { clock - it.value <= window }.keys
        when (mode) {
            PlaybackMode.WAIT_FOR_ME -> {
                val expected = expectedNotes(cursor)
                for (pitch in expected) armedNotes.remove(pitch)
                matchArmed(recent.intersect(expected))
            }
            PlaybackMode.CONTINUOUS -> {
                matchContinuous(recent, emptySet())
            }
        }
    }

    private fun match(fresh: Set<Int>, wrongCandidates: Set<Int>) {
        when (mode) {
            PlaybackMode.WAIT_FOR_ME -> {
                if (state != PlaybackState.WAITING || cursor >= song.steps.size) return
                val expected = expectedNotes(cursor)
                val wrong = wrongCandidates.minus(expected)
                if (wrong.isNotEmpty()) {
                    stats.wrongNotes += wrong.size
                    stats.currentStreak = 0
                }
                matchArmed(fresh.intersect(expected))
            }
            PlaybackMode.CONTINUOUS -> {
                matchContinuous(fresh, wrongCandidates)
            }
        }
    }

    private fun matchArmed(notes: Set<Int>) {
        if (cursor >= song.steps.size) return
        for (note in notes) {
            latchedNotes[note] = clock
            armedNotes.remove(note)
        }
        val expected = expectedNotes(cursor)
        if (expected.isEmpty() || !latchedNotes.keys.containsAll(expected)) return

        val index = cursor
        stats.notesHit += expected.size
        stats.stepsCompleted += 1
        stats.currentStreak += 1
        stats.bestStreak = max(stats.bestStreak, stats.currentStreak)
        stepStatuses[index] = StepStatus.COMPLETED
        pendingEvents.add(PracticeEvent.StepCompleted(index))
        emitAudio(index)
        finishCurrentStep()
    }

    private fun checkPartialChordGrace() {
        val grace = configuration.partialChordGraceSeconds ?: return
        if (mode != PlaybackMode.WAIT_FOR_ME || state != PlaybackState.WAITING || cursor >= song.steps.size) return
        val expected = expectedNotes(cursor)
        if (expected.size < 2) return
        val matchedCount = expected.intersect(latchedNotes.keys).size
        val missingCount = expected.size - matchedCount
        if (matchedCount < 1 || missingCount != 1) return
        val firstLatch = latchedNotes.values.minOrNull() ?: return
        if (clock - firstLatch < grace) return

        val index = cursor
        stats.notesHit += matchedCount
        stats.stepsCompleted += 1
        stats.currentStreak += 1
        stats.bestStreak = max(stats.bestStreak, stats.currentStreak)
        stepStatuses[index] = StepStatus.COMPLETED
        pendingEvents.add(PracticeEvent.StepCompleted(index))
        emitAudio(index)
        finishCurrentStep()
    }

    private fun finishCurrentStep() {
        latchedNotes.clear()
        cursor += 1
        scoringCursor = cursor
        if (state == PlaybackState.WAITING) state = PlaybackState.PLAYING
        if (state == PlaybackState.PLAYING) advance(0.0)
    }

    private fun expireLatches() {
        if (mode != PlaybackMode.WAIT_FOR_ME) return
        val expired = mutableListOf<Int>()
        for ((note, time) in latchedNotes) {
            if (clock - time > configuration.rollWindow) {
                if (previouslyHeard.contains(note)) {
                    latchedNotes[note] = clock
                } else {
                    expired.add(note)
                }
            }
        }
        for (note in expired) latchedNotes.remove(note)
    }

    private fun jumpToLoopStart(loop: ClosedFloatingPointRange<Double>) {
        if (mode == PlaybackMode.CONTINUOUS) {
            finalizePassedContinuousSteps(loop.endInclusive)
        }
        for (index in song.steps.indices) {
            val t = song.steps[index].timeSeconds
            if (t >= loop.start && t < loop.endInclusive) {
                stepStatuses[index] = StepStatus.PENDING
            }
        }
        playhead = loop.start
        cursor = firstStepIndexAtOrAfter(playhead)
        scoringCursor = cursor
        clearMatchState()
        pendingEvents.add(PracticeEvent.Looped)
    }

    private fun finish() {
        if (mode == PlaybackMode.CONTINUOUS) {
            finalizePassedContinuousSteps(Double.POSITIVE_INFINITY)
        }
        playhead = song.durationSeconds
        state = PlaybackState.FINISHED
        pendingEvents.add(PracticeEvent.Finished)
    }

    private fun emitAudio(stepIndex: Int, forceAllNotes: Boolean = false) {
        val shouldPlay: (SongNote) -> Boolean = if (forceAllNotes) {
            { true }
        } else {
            when (mode) {
                PlaybackMode.WAIT_FOR_ME -> {
                    if (!autoPlayAccompaniment || handSelection == HandSelection.BOTH) return
                    { !handSelection.includes(it.hand) }
                }
                PlaybackMode.CONTINUOUS -> {
                    if (playsReferenceAudio) {
                        { true }
                    } else if (autoPlayAccompaniment && handSelection != HandSelection.BOTH) {
                        { !handSelection.includes(it.hand) }
                    } else {
                        return
                    }
                }
            }
        }

        for (note in song.steps[stepIndex].notes) {
            if (shouldPlay(note)) {
                pendingEvents.add(
                    PracticeEvent.PlayNote(
                        pitch = note.pitch,
                        velocity = note.velocity,
                        duration = note.durationSeconds / speed
                    )
                )
                if (mode == PlaybackMode.WAIT_FOR_ME || !handSelection.includes(note.hand)) {
                    echoSuppressedUntil[note.pitch] = clock + configuration.synthEchoSuppression
                }
            }
        }
    }

    private fun clearMatchState() {
        latchedNotes.clear()
        armedNotes.clear()
        continuousHits.clear()
    }

    private fun firstStepIndexAtOrAfter(seconds: Double): Int {
        val idx = song.steps.indexOfFirst { it.timeSeconds >= seconds }
        return if (idx >= 0) idx else song.steps.size
    }

    private val scoringWindow: Double
        get() = configuration.continuousWindow * speed

    private fun scoringStepIndices(): List<Int> {
        val indices = mutableListOf<Int>()
        var index = scoringCursor
        val win = scoringWindow
        while (index < song.steps.size && song.steps[index].timeSeconds <= playhead + win) {
            if (stepStatuses[index] == StepStatus.PENDING &&
                abs(song.steps[index].timeSeconds - playhead) <= win
            ) {
                indices.add(index)
            }
            index += 1
        }
        return indices
    }

    private fun matchContinuous(fresh: Set<Int>, wrongCandidates: Set<Int>) {
        val unmatched = fresh.toMutableSet()
        for (index in scoringStepIndices()) {
            val expected = expectedNotes(index)
            if (expected.isEmpty()) continue
            val hits = continuousHits.getOrPut(index) { mutableSetOf() }
            val newHits = unmatched.intersect(expected).minus(hits)
            hits.addAll(newHits)
            unmatched.removeAll(newHits)
            for (note in newHits) armedNotes.remove(note)
            if (hits.containsAll(expected)) {
                completeContinuous(index, hits)
            }
        }
        val wrong = unmatched.intersect(wrongCandidates)
        if (wrong.isNotEmpty()) {
            stats.wrongNotes += wrong.size
            stats.currentStreak = 0
        }
    }

    private fun completeContinuous(index: Int, hits: Set<Int>) {
        stats.notesHit += hits.size
        stats.stepsCompleted += 1
        stats.currentStreak += 1
        stats.bestStreak = max(stats.bestStreak, stats.currentStreak)
        stepStatuses[index] = StepStatus.COMPLETED
        continuousHits.remove(index)
        pendingEvents.add(PracticeEvent.StepCompleted(index))
    }

    private fun finalizePassedContinuousSteps(through: Double? = null) {
        val deadline = through ?: (playhead - scoringWindow)
        while (scoringCursor < song.steps.size && song.steps[scoringCursor].timeSeconds < deadline) {
            val index = scoringCursor
            if (stepStatuses[index] == StepStatus.PENDING) {
                val expected = expectedNotes(index)
                if (expected.isEmpty()) {
                    stepStatuses[index] = StepStatus.AUTO_PASSED
                } else {
                    val hits = continuousHits[index] ?: emptySet()
                    stats.notesHit += hits.size
                    stats.notesMissed += expected.size - hits.size
                    stats.currentStreak = 0
                    stepStatuses[index] = StepStatus.MISSED
                    continuousHits.remove(index)
                }
            }
            scoringCursor += 1
        }
    }
}
