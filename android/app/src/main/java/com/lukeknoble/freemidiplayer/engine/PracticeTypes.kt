package com.lukeknoble.freemidiplayer.engine

import com.lukeknoble.freemidiplayer.midi.Hand

enum class HandSelection(val label: String) {
    BOTH("Both"),
    RIGHT("Right"),
    LEFT("Left");

    fun includes(hand: Hand): Boolean {
        return when (this) {
            BOTH -> true
            RIGHT -> hand == Hand.RIGHT
            LEFT -> hand == Hand.LEFT
        }
    }
}

enum class PlaybackMode {
    WAIT_FOR_ME,
    CONTINUOUS
}

enum class PlaybackState {
    PAUSED,
    PLAYING,
    WAITING,
    FINISHED
}

enum class StepStatus {
    PENDING,
    COMPLETED,
    SKIPPED,
    MISSED,
    AUTO_PASSED
}

sealed class PracticeEvent {
    data class PlayNote(val pitch: Int, val velocity: Int, val duration: Double) : PracticeEvent()
    data class StepCompleted(val index: Int) : PracticeEvent()
    data object Looped : PracticeEvent()
    data object Finished : PracticeEvent()
}

data class PracticeStats(
    var notesHit: Int = 0,
    var notesMissed: Int = 0,
    var wrongNotes: Int = 0,
    var stepsCompleted: Int = 0,
    var stepsSkipped: Int = 0,
    var currentStreak: Int = 0,
    var bestStreak: Int = 0
) {
    val accuracy: Double
        get() {
            val attempts = notesHit + notesMissed + wrongNotes
            return if (attempts == 0) 1.0 else notesHit.toDouble() / attempts.toDouble()
        }
}

/**
 * Enforces that ads never block or interrupt active piano gameplay.
 */
object AdPlacementPolicy {
    fun isGameplayActive(state: PlaybackState): Boolean {
        return state == PlaybackState.PLAYING || state == PlaybackState.WAITING
    }

    fun allowsAdInPracticeView(state: PlaybackState): Boolean {
        return state == PlaybackState.FINISHED
    }

    fun allowsPostSongInterstitial(
        state: PlaybackState,
        adsEnabled: Boolean = true,
        completedSongsSinceLastAd: Int,
        minimumSongsBetweenInterstitials: Int = 1,
        secondsSinceLastInterstitial: Double? = null,
        minimumCooldownSeconds: Double = 90.0
    ): Boolean {
        if (!adsEnabled) return false
        if (state != PlaybackState.FINISHED) return false
        if (completedSongsSinceLastAd < minimumSongsBetweenInterstitials.coerceAtLeast(1)) return false
        if (secondsSinceLastInterstitial != null && secondsSinceLastInterstitial < minimumCooldownSeconds) {
            return false
        }
        return true
    }
}
