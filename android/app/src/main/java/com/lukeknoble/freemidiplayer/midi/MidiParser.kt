package com.lukeknoble.freemidiplayer.midi

import kotlin.math.max

class MidiParseException(message: String) : Exception(message)

/**
 * Pure Kotlin Standard MIDI File (Format 0 and Format 1) parser.
 */
object MidiParser {
    const val DEFAULT_CHORD_WINDOW: Double = 0.035
    private const val PERCUSSION_CHANNEL: Int = 9
    private const val DEFAULT_MICROSECONDS_PER_QUARTER: Int = 500_000

    fun parse(
        bytes: ByteArray,
        title: String? = null,
        composer: String = "",
        chordWindow: Double = DEFAULT_CHORD_WINDOW
    ): MidiSong {
        if (bytes.isEmpty()) throw MidiParseException("MIDI file is empty")

        val reader = ByteReader(bytes)
        val magic = reader.readAscii(4)
        if (magic != "MThd") throw MidiParseException("Not a valid Standard MIDI file (missing MThd)")

        val headerLength = reader.readUInt32().toInt()
        if (headerLength < 6) throw MidiParseException("Invalid MIDI header length: $headerLength")
        val format = reader.readUInt16()
        val declaredTracks = reader.readUInt16()
        val division = reader.readUInt16()
        reader.skip(headerLength - 6)

        if (format != 0 && format != 1) {
            throw MidiParseException("Unsupported MIDI format: $format")
        }
        if (declaredTracks <= 0) {
            throw MidiParseException("MIDI file contains no tracks")
        }

        val timing = parseTickTiming(division)
        val parsedTracks = mutableListOf<ParsedTrack>()

        while (!reader.isAtEnd && parsedTracks.size < declaredTracks) {
            if (reader.remaining < 8) break
            val chunkId = reader.readAscii(4)
            val chunkLength = reader.readUInt32().toInt()
            if (chunkLength < 0 || chunkLength > reader.remaining) {
                throw MidiParseException("Truncated MIDI chunk ($chunkId)")
            }
            val chunkBytes = reader.readBytes(chunkLength)
            if (chunkId == "MTrk") {
                parsedTracks.add(parseTrack(chunkBytes))
            }
        }
        if (parsedTracks.isEmpty()) {
            throw MidiParseException("No MTrk chunks found")
        }

        val tempoMap = TempoMap(
            changes = parsedTracks.flatMap { it.tempoChanges },
            timing = timing,
            defaultMicrosecondsPerQuarter = DEFAULT_MICROSECONDS_PER_QUARTER
        )

        val rawNoteCount = parsedTracks.sumOf { it.notes.size }
        val playableByTrack = parsedTracks.map { track ->
            track.notes.filter {
                it.channel != PERCUSSION_CHANNEL && it.pitch in MidiNote.PIANO_RANGE
            }
        }
        val handAssigner = HandAssigner(playableByTrack)

        val notes = mutableListOf<SongNote>()
        for ((trackIndex, trackNotes) in playableByTrack.withIndex()) {
            for (raw in trackNotes) {
                notes.add(
                    SongNote(
                        pitch = raw.pitch,
                        velocity = raw.velocity,
                        startTick = raw.startTick,
                        startSeconds = tempoMap.secondsAtTick(raw.startTick),
                        endSeconds = tempoMap.secondsAtTick(raw.endTick),
                        track = trackIndex,
                        channel = raw.channel,
                        hand = handAssigner.handFor(trackIndex, raw.pitch)
                    )
                )
            }
        }
        if (notes.isEmpty()) {
            throw MidiParseException("MIDI file contains no playable piano notes (A0..C8)")
        }

        notes.sortWith(compareBy<SongNote> { it.startSeconds }.thenBy { it.pitch })

        val timeSignatures = parsedTracks.flatMap { it.timeSignatures }
            .sortedBy { it.tick }
            .map {
                TimeSignatureEvent(
                    tick = it.tick,
                    numerator = it.numerator,
                    denominator = it.denominator,
                    seconds = tempoMap.secondsAtTick(it.tick)
                )
            }

        val duration = notes.maxOfOrNull { it.endSeconds } ?: 0.0
        val lastTick = notes.maxOfOrNull { it.startTick } ?: 0
        val trackNames = parsedTracks.mapNotNull { it.name }

        return MidiSong(
            title = title ?: trackNames.firstOrNull() ?: "Untitled",
            composer = composer,
            format = format,
            trackNames = trackNames,
            tempoEvents = tempoMap.events,
            timeSignatures = timeSignatures,
            notes = notes,
            steps = groupIntoSteps(notes, chordWindow),
            durationSeconds = duration,
            barStartSeconds = barStarts(timeSignatures, timing, lastTick, tempoMap),
            droppedNoteCount = rawNoteCount - notes.size
        )
    }

    fun groupIntoSteps(sortedNotes: List<SongNote>, chordWindow: Double = DEFAULT_CHORD_WINDOW): List<ChordStep> {
        val steps = mutableListOf<ChordStep>()
        var current = mutableListOf<SongNote>()

        fun flush() {
            val first = current.firstOrNull() ?: return
            steps.add(ChordStep(index = steps.size, timeSeconds = first.startSeconds, notes = current.toList()))
            current = mutableListOf()
        }

        for (note in sortedNotes) {
            val first = current.firstOrNull()
            if (first != null && note.startSeconds - first.startSeconds > chordWindow) {
                flush()
            }
            current.add(note)
        }
        flush()
        return steps
    }

    private fun parseTrack(bytes: ByteArray): ParsedTrack {
        val reader = ByteReader(bytes)
        val track = ParsedTrack()
        var tick = 0
        var runningStatus: Int? = null
        val sounding = mutableMapOf<SoundingKey, ArrayDeque<SoundingNote>>()

        while (!reader.isAtEnd) {
            tick += reader.readVariableLengthQuantity()
            if (reader.isAtEnd) break
            val first = reader.readByte()

            when (first) {
                0xFF -> {
                    val type = reader.readByte()
                    val length = reader.readVariableLengthQuantity()
                    val payload = reader.readBytes(length)
                    handleMeta(type, payload, tick, track)
                    if (type == 0x2F) {
                        reader.skipToEnd()
                    }
                }
                0xF0, 0xF7 -> {
                    val length = reader.readVariableLengthQuantity()
                    reader.skip(length)
                }
                in 0xF1..0xFE -> {
                    throw MidiParseException("Invalid MIDI system status byte: 0x${first.toString(16)}")
                }
                else -> {
                    val status: Int
                    var firstData: Int
                    if ((first and 0x80) != 0) {
                        status = first
                        runningStatus = first
                        firstData = reader.readByte()
                    } else {
                        status = runningStatus ?: throw MidiParseException("Missing MIDI running status")
                        firstData = first
                    }
                    firstData = firstData and 0x7F

                    val kind = status and 0xF0
                    val channel = status and 0x0F
                    val secondData = if (kind == 0xC0 || kind == 0xD0) 0 else (reader.readByte() and 0x7F)
                    val key = SoundingKey(channel, firstData)

                    if (kind == 0x90 && secondData > 0) {
                        val queue = sounding.getOrPut(key) { ArrayDeque() }
                        queue.addLast(SoundingNote(startTick = tick, velocity = secondData))
                    } else if (kind == 0x80 || kind == 0x90) {
                        val queue = sounding[key]
                        if (!queue.isNullOrEmpty()) {
                            val started = queue.removeFirst()
                            track.notes.add(
                                RawNote(
                                    pitch = firstData,
                                    velocity = started.velocity,
                                    channel = channel,
                                    startTick = started.startTick,
                                    endTick = max(tick, started.startTick + 1)
                                )
                            )
                        }
                    }
                }
            }
        }

        for ((key, queue) in sounding) {
            for (started in queue) {
                track.notes.add(
                    RawNote(
                        pitch = key.pitch,
                        velocity = started.velocity,
                        channel = key.channel,
                        startTick = started.startTick,
                        endTick = max(tick, started.startTick + 1)
                    )
                )
            }
        }
        track.notes.sortWith(compareBy<RawNote> { it.startTick }.thenBy { it.pitch })
        return track
    }

    private fun handleMeta(type: Int, payload: ByteArray, tick: Int, track: ParsedTrack) {
        when (type) {
            0x03 -> {
                val name = payload.toString(Charsets.UTF_8).trim()
                if (track.name == null && name.isNotEmpty()) {
                    track.name = name
                }
            }
            0x51 -> {
                if (payload.size == 3) {
                    val us = ((payload[0].toInt() and 0xFF) shl 16) or
                        ((payload[1].toInt() and 0xFF) shl 8) or
                        (payload[2].toInt() and 0xFF)
                    if (us > 0) {
                        track.tempoChanges.add(TempoChange(tick = tick, microsecondsPerQuarter = us))
                    }
                }
            }
            0x58 -> {
                if (payload.size >= 2) {
                    val num = payload[0].toInt() and 0xFF
                    val denPow = payload[1].toInt() and 0xFF
                    if (num > 0 && denPow < 8) {
                        track.timeSignatures.add(
                            RawTimeSignature(
                                tick = tick,
                                numerator = num,
                                denominator = 1 shl denPow
                            )
                        )
                    }
                }
            }
        }
    }

    private fun barStarts(
        timeSignatures: List<TimeSignatureEvent>,
        timing: TickTiming,
        lastTick: Int,
        tempoMap: TempoMap
    ): List<Double> {
        val ticksPerQuarter = (timing as? TickTiming.TicksPerQuarter)?.ticks ?: return emptyList()
        val bars = mutableListOf<Double>()
        var tick = 0
        var numerator = 4
        var denominator = 4
        var nextSig = 0

        while (tick <= lastTick) {
            while (nextSig < timeSignatures.size && timeSignatures[nextSig].tick <= tick) {
                numerator = timeSignatures[nextSig].numerator
                denominator = timeSignatures[nextSig].denominator
                nextSig += 1
            }
            bars.add(tempoMap.secondsAtTick(tick))
            tick += max(1, ticksPerQuarter * 4 * numerator / denominator)
        }
        return bars
    }

    private fun parseTickTiming(division: Int): TickTiming {
        return if ((division and 0x8000) == 0) {
            if (division <= 0) throw MidiParseException("Invalid MIDI ticksPerQuarter: $division")
            TickTiming.TicksPerQuarter(division)
        } else {
            val fpsByte = (division shr 8).toByte().toInt()
            val framesPerSecond = -fpsByte
            val ticksPerFrame = division and 0xFF
            if (framesPerSecond <= 0 || ticksPerFrame <= 0) {
                throw MidiParseException("Invalid SMPTE division: $division")
            }
            val rate = if (framesPerSecond == 29) 29.97 else framesPerSecond.toDouble()
            TickTiming.Smpte(rate * ticksPerFrame.toDouble())
        }
    }

    private sealed class TickTiming {
        data class TicksPerQuarter(val ticks: Int) : TickTiming()
        data class Smpte(val ticksPerSecond: Double) : TickTiming()
    }

    private data class TempoChange(val tick: Int, val microsecondsPerQuarter: Int)
    private data class RawNote(
        val pitch: Int,
        val velocity: Int,
        val channel: Int,
        val startTick: Int,
        val endTick: Int
    )
    private data class RawTimeSignature(val tick: Int, val numerator: Int, val denominator: Int)
    private class ParsedTrack {
        var name: String? = null
        val notes = mutableListOf<RawNote>()
        val tempoChanges = mutableListOf<TempoChange>()
        val timeSignatures = mutableListOf<RawTimeSignature>()
    }
    private data class SoundingKey(val channel: Int, val pitch: Int)
    private data class SoundingNote(val startTick: Int, val velocity: Int)

    private class TempoMap(
        changes: List<TempoChange>,
        private val timing: TickTiming,
        defaultMicrosecondsPerQuarter: Int
    ) {
        val events: List<TempoEvent>

        init {
            val ordered = changes.withIndex()
                .sortedWith(compareBy<IndexedValue<TempoChange>> { it.value.tick }.thenBy { it.index })
                .map { it.value }

            val built = mutableListOf(
                TempoEvent(tick = 0, microsecondsPerQuarter = defaultMicrosecondsPerQuarter, seconds = 0.0)
            )
            for (change in ordered) {
                val last = built.last()
                if (change.tick == last.tick) {
                    built[built.lastIndex] = TempoEvent(
                        tick = last.tick,
                        microsecondsPerQuarter = change.microsecondsPerQuarter,
                        seconds = last.seconds
                    )
                } else {
                    val elapsed = durationSeconds(change.tick - last.tick, last, timing)
                    built.add(
                        TempoEvent(
                            tick = change.tick,
                            microsecondsPerQuarter = change.microsecondsPerQuarter,
                            seconds = last.seconds + elapsed
                        )
                    )
                }
            }
            events = built
        }

        fun secondsAtTick(tick: Int): Double {
            var low = 0
            var high = events.lastIndex
            while (low < high) {
                val mid = (low + high + 1) ushr 1
                if (events[mid].tick <= tick) {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            val tempo = events[low]
            return tempo.seconds + durationSeconds(tick - tempo.tick, tempo, timing)
        }

        private fun durationSeconds(ticks: Int, tempo: TempoEvent, timing: TickTiming): Double {
            return when (timing) {
                is TickTiming.TicksPerQuarter ->
                    ticks.toDouble() * tempo.microsecondsPerQuarter.toDouble() / 1_000_000.0 / timing.ticks.toDouble()
                is TickTiming.Smpte ->
                    ticks.toDouble() / timing.ticksPerSecond
            }
        }
    }

    private class HandAssigner(tracks: List<List<RawNote>>) {
        private val handsByTrack: Map<Int, Hand>

        init {
            val averages = mutableMapOf<Int, Double>()
            for ((index, notes) in tracks.withIndex()) {
                if (notes.isNotEmpty()) {
                    averages[index] = notes.sumOf { it.pitch }.toDouble() / notes.size.toDouble()
                }
            }
            val high = averages.values.maxOrNull()
            val low = averages.values.minOrNull()
            handsByTrack = if (averages.size >= 2 && high != null && low != null && high > low) {
                val midpoint = (high + low) / 2.0
                averages.mapValues { (_, avg) -> if (avg >= midpoint) Hand.RIGHT else Hand.LEFT }
            } else {
                emptyMap()
            }
        }

        fun handFor(track: Int, pitch: Int): Hand {
            return handsByTrack[track] ?: if (pitch >= MidiNote.MIDDLE_C) Hand.RIGHT else Hand.LEFT
        }
    }

    private class ByteReader(private val bytes: ByteArray) {
        private var pos = 0

        val isAtEnd: Boolean
            get() = pos >= bytes.size

        val remaining: Int
            get() = bytes.size - pos

        fun readByte(): Int {
            if (pos >= bytes.size) throw MidiParseException("Unexpected end of MIDI file")
            return bytes[pos++].toInt() and 0xFF
        }

        fun readBytes(count: Int): ByteArray {
            if (count < 0 || pos + count > bytes.size) {
                throw MidiParseException("Unexpected end of MIDI file reading $count bytes")
            }
            val slice = bytes.copyOfRange(pos, pos + count)
            pos += count
            return slice
        }

        fun readAscii(count: Int): String {
            return readBytes(count).toString(Charsets.US_ASCII)
        }

        fun readUInt16(): Int {
            val b0 = readByte()
            val b1 = readByte()
            return (b0 shl 8) or b1
        }

        fun readUInt32(): Long {
            val b0 = readByte().toLong()
            val b1 = readByte().toLong()
            val b2 = readByte().toLong()
            val b3 = readByte().toLong()
            return (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3
        }

        fun readVariableLengthQuantity(): Int {
            var value = 0
            var count = 0
            while (true) {
                if (count >= 4) throw MidiParseException("MIDI variable-length quantity exceeds 4 bytes")
                val b = readByte()
                value = (value shl 7) or (b and 0x7F)
                count += 1
                if ((b and 0x80) == 0) break
            }
            return value
        }

        fun skip(count: Int) {
            if (count <= 0) return
            pos = (pos + count).coerceAtMost(bytes.size)
        }

        fun skipToEnd() {
            pos = bytes.size
        }
    }
}
