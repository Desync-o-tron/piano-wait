package com.lukeknoble.freemidiplayer

import com.lukeknoble.freemidiplayer.audio.PianoVoiceBank
import com.lukeknoble.freemidiplayer.engine.AdPlacementPolicy
import com.lukeknoble.freemidiplayer.engine.HandSelection
import com.lukeknoble.freemidiplayer.engine.PlaybackMode
import com.lukeknoble.freemidiplayer.engine.PlaybackState
import com.lukeknoble.freemidiplayer.engine.WaitModeEngine
import com.lukeknoble.freemidiplayer.layout.PianoKeyboardLayout
import com.lukeknoble.freemidiplayer.layout.PracticeZoom
import com.lukeknoble.freemidiplayer.midi.MidiNote
import com.lukeknoble.freemidiplayer.midi.MidiParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

class FreeMidiPlayerCoreTest {

    private fun readAssetSongBytes(fileName: String): ByteArray {
        val candidates = listOf(
            File("src/main/assets/songs/$fileName"),
            File("app/src/main/assets/songs/$fileName")
        )
        val found = candidates.firstOrNull { it.exists() }
            ?: throw IllegalStateException("Missing asset song file: $fileName")
        return found.readBytes()
    }

    @Test
    fun midiNoteHelpersWorkAcross88KeyRange() {
        assertEquals(60, MidiNote.parse("C4"))
        assertEquals(69, MidiNote.parse("A4"))
        assertEquals(66, MidiNote.parse("F#4"))
        assertEquals("C4", MidiNote.name(60))
        assertEquals(440.0, MidiNote.frequency(69), 0.001)
        assertFalse(MidiNote.isBlackKey(60))
        assertTrue(MidiNote.isBlackKey(61))
    }

    @Test
    fun bundledClassicalMidiSongsParseCleanly() {
        val files = listOf(
            "ode_to_joy.mid",
            "minuet_in_g.mid",
            "fur_elise_opening.mid",
            "prelude_in_c.mid",
            "twinkle_twinkle.mid",
            "chord_drill.mid"
        )
        for (name in files) {
            val song = MidiParser.parse(readAssetSongBytes(name), title = name)
            assertTrue("Expected notes in $name", song.noteCount > 10)
            assertTrue("Expected steps in $name", song.steps.isNotEmpty())
            assertTrue("Expected positive duration in $name", song.durationSeconds > 5.0)
            assertNotNull("Expected pitch range in $name", song.pitchRange)
        }
    }

    @Test
    fun waitModeStopsAtEveryChordUntilPlayed() {
        val song = MidiParser.parse(readAssetSongBytes("ode_to_joy.mid"), title = "Ode to Joy")
        val engine = WaitModeEngine(song = song, mode = PlaybackMode.WAIT_FOR_ME)

        engine.play()
        assertEquals(PlaybackState.WAITING, engine.state)
        assertEquals(0, engine.currentStepIndex)

        val firstExpected = engine.waitingNotes
        assertEquals(setOf(48, 64), firstExpected) // C3 + E4

        // Ticking while waiting does not advance playhead past step 0
        engine.tick(2.0)
        assertEquals(PlaybackState.WAITING, engine.state)
        assertEquals(0, engine.currentStepIndex)

        // Playing only C3 latches C3 but still waits for E4
        engine.registerKeyPress(48)
        assertEquals(PlaybackState.WAITING, engine.state)
        assertTrue(engine.latched.contains(48))

        // Playing E4 completes step 0
        engine.registerKeyPress(64)
        assertEquals(1, engine.stats.stepsCompleted)
        assertEquals(2, engine.stats.notesHit)
    }

    @Test
    fun continuousModeScalesWithTempoAndSupportsLooping() {
        val song = MidiParser.parse(readAssetSongBytes("twinkle_twinkle.mid"), title = "Twinkle")
        val engine = WaitModeEngine(song = song, mode = PlaybackMode.CONTINUOUS)

        engine.updateSpeed(2.0)
        assertEquals(2.0, engine.speed, 1e-6)

        engine.updateSpeed(0.25)
        assertEquals(0.25, engine.speed, 1e-6)

        assertTrue(engine.setLoop(start = 2.0, end = 6.0))
        engine.play()
        engine.updateSpeed(1.0)
        engine.tick(5.0)
        // Should have looped back into [2.0, 6.0]
        assertTrue(engine.playhead >= 2.0 && engine.playhead < 6.0)
    }

    @Test
    fun keyboardViewportZoomsAndPansAcross88Keys() {
        val song = MidiParser.parse(readAssetSongBytes("minuet_in_g.mid"), title = "Minuet in G")
        val zoom = PracticeZoom(song)
        val fittedWidth = zoom.keyboard.width
        assertTrue(fittedWidth < 1.0)

        zoom.showAllKeys()
        assertEquals(1.0, zoom.keyboard.width, 1e-6)
        assertEquals(52, zoom.keyboard.layout.whiteKeyCount)

        zoom.zoomIn()
        assertTrue(zoom.keyboard.width < 1.0)
        val beforeStart = zoom.keyboard.start
        zoom.panRight()
        assertTrue(zoom.keyboard.start >= beforeStart)
    }

    @Test
    fun polyphonicPianoVoiceBankSynthesizesWaveform() {
        val bank = PianoVoiceBank(sampleRate = 44_100.0)
        bank.noteOn(note = 60, velocity = 100, durationSeconds = 0.5)
        bank.noteOn(note = 64, velocity = 95, durationSeconds = 0.5)
        bank.noteOn(note = 67, velocity = 95, durationSeconds = 0.5)
        assertEquals(3, bank.activeVoiceCount)

        val buffer = FloatArray(512)
        bank.render(buffer, buffer.size)
        val peak = buffer.maxOf { abs(it) }
        assertTrue("Expected audible waveform peak > 0.01, got $peak", peak > 0.01f)
    }

    @Test
    fun adPlacementPolicyNeverInterruptsGameplay() {
        assertTrue(AdPlacementPolicy.isGameplayActive(PlaybackState.PLAYING))
        assertTrue(AdPlacementPolicy.isGameplayActive(PlaybackState.WAITING))
        assertFalse(AdPlacementPolicy.isGameplayActive(PlaybackState.PAUSED))
        assertFalse(AdPlacementPolicy.isGameplayActive(PlaybackState.FINISHED))

        assertFalse(AdPlacementPolicy.allowsAdInPracticeView(PlaybackState.PLAYING))
        assertFalse(AdPlacementPolicy.allowsAdInPracticeView(PlaybackState.WAITING))
        assertFalse(AdPlacementPolicy.allowsAdInPracticeView(PlaybackState.PAUSED))
        assertTrue(AdPlacementPolicy.allowsAdInPracticeView(PlaybackState.FINISHED))

        assertFalse(
            AdPlacementPolicy.allowsPostSongInterstitial(
                state = PlaybackState.PLAYING,
                completedSongsSinceLastAd = 3
            )
        )
        assertFalse(
            AdPlacementPolicy.allowsPostSongInterstitial(
                state = PlaybackState.WAITING,
                completedSongsSinceLastAd = 3
            )
        )
        assertTrue(
            AdPlacementPolicy.allowsPostSongInterstitial(
                state = PlaybackState.FINISHED,
                completedSongsSinceLastAd = 1,
                secondsSinceLastInterstitial = 120.0
            )
        )
        assertFalse(
            AdPlacementPolicy.allowsPostSongInterstitial(
                state = PlaybackState.FINISHED,
                completedSongsSinceLastAd = 1,
                secondsSinceLastInterstitial = 30.0,
                minimumCooldownSeconds = 90.0
            )
        )
    }
}
