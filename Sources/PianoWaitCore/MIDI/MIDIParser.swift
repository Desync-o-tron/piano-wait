import Foundation

/// Pure Swift parser for Format 0 and Format 1 Standard MIDI Files.
public enum MIDIParser {
    public static let defaultChordWindow: TimeInterval = 0.035

    private static let percussionChannel: UInt8 = 9
    private static let defaultMicrosecondsPerQuarter = 500_000

    public static func parse(
        data: Data,
        title: String? = nil,
        chordWindow: TimeInterval = defaultChordWindow
    ) throws -> MIDISong {
        guard !data.isEmpty else { throw MIDIParseError.emptyData }

        var reader = ByteReader(bytes: [UInt8](data))
        guard let magic = try? reader.readBytes(4), magic == Array("MThd".utf8) else {
            throw MIDIParseError.notMIDIFile
        }

        let headerLength = Int(try reader.readUInt32())
        guard headerLength >= 6 else { throw MIDIParseError.invalidHeader }
        let format = Int(try reader.readUInt16())
        let declaredTracks = Int(try reader.readUInt16())
        let division = try reader.readUInt16()
        try reader.skip(headerLength - 6)

        guard format == 0 || format == 1 else { throw MIDIParseError.unsupportedFormat(format) }
        guard declaredTracks > 0 else { throw MIDIParseError.noTracks }
        let timing = try TickTiming(division: division)

        var parsedTracks: [ParsedTrack] = []
        while !reader.isAtEnd && parsedTracks.count < declaredTracks {
            let chunkID = try reader.readBytes(4)
            let chunkLength = Int(try reader.readUInt32())
            let chunk = try reader.readBytes(chunkLength)
            // The SMF spec requires readers to ignore chunk types they do not recognize.
            guard chunkID == Array("MTrk".utf8) else { continue }
            parsedTracks.append(try parseTrack(chunk))
        }
        guard !parsedTracks.isEmpty else { throw MIDIParseError.noTracks }

        let tempoMap = TempoMap(
            changes: parsedTracks.flatMap(\.tempoChanges),
            timing: timing,
            defaultMicrosecondsPerQuarter: defaultMicrosecondsPerQuarter
        )

        let isPlayable: (RawNote) -> Bool = {
            $0.channel != percussionChannel && MIDINote.pianoRange.contains($0.pitch)
        }
        let rawNoteCount = parsedTracks.reduce(0) { $0 + $1.notes.count }
        let playableByTrack = parsedTracks.map { $0.notes.filter(isPlayable) }
        let hands = HandAssigner(tracks: playableByTrack)

        var notes: [SongNote] = []
        for (trackIndex, trackNotes) in playableByTrack.enumerated() {
            for raw in trackNotes {
                notes.append(SongNote(
                    pitch: raw.pitch,
                    velocity: raw.velocity,
                    startTick: raw.startTick,
                    startSeconds: tempoMap.seconds(atTick: raw.startTick),
                    endSeconds: tempoMap.seconds(atTick: raw.endTick),
                    track: trackIndex,
                    channel: raw.channel,
                    hand: hands.hand(forTrack: trackIndex, pitch: raw.pitch)
                ))
            }
        }
        guard !notes.isEmpty else { throw MIDIParseError.noPlayableNotes }
        notes.sort { ($0.startSeconds, $0.pitch) < ($1.startSeconds, $1.pitch) }

        let timeSignatures = parsedTracks.flatMap(\.timeSignatures)
            .sorted { $0.tick < $1.tick }
            .map {
                TimeSignatureEvent(
                    tick: $0.tick,
                    numerator: $0.numerator,
                    denominator: $0.denominator,
                    seconds: tempoMap.seconds(atTick: $0.tick)
                )
            }
        let duration = notes.map(\.endSeconds).max() ?? 0
        let lastTick = notes.map(\.startTick).max() ?? 0
        let trackNames = parsedTracks.compactMap(\.name)

        return MIDISong(
            title: title ?? trackNames.first ?? "Untitled",
            format: format,
            trackNames: trackNames,
            tempoEvents: tempoMap.events,
            timeSignatures: timeSignatures,
            notes: notes,
            steps: groupIntoSteps(notes, chordWindow: chordWindow),
            durationSeconds: duration,
            barStartSeconds: barStarts(
                timeSignatures: timeSignatures,
                timing: timing,
                lastTick: lastTick,
                tempoMap: tempoMap
            ),
            droppedNoteCount: rawNoteCount - notes.count
        )
    }

    /// Groups notes into steps, measuring the window from the first note of the group so that a
    /// fast run cannot chain into one enormous "chord".
    public static func groupIntoSteps(_ sortedNotes: [SongNote], chordWindow: TimeInterval) -> [ChordStep] {
        var steps: [ChordStep] = []
        var current: [SongNote] = []

        func flush() {
            guard let first = current.first else { return }
            steps.append(ChordStep(index: steps.count, timeSeconds: first.startSeconds, notes: current))
            current = []
        }

        for note in sortedNotes {
            if let first = current.first, note.startSeconds - first.startSeconds > chordWindow {
                flush()
            }
            current.append(note)
        }
        flush()
        return steps
    }

    // MARK: - Track parsing

    private static func parseTrack(_ bytes: [UInt8]) throws -> ParsedTrack {
        var reader = ByteReader(bytes: bytes)
        var track = ParsedTrack()
        var tick = 0
        var runningStatus: UInt8?
        var sounding: [SoundingKey: [SoundingNote]] = [:]

        while !reader.isAtEnd {
            tick += try reader.readVariableLengthQuantity()
            let first = try reader.readByte()

            switch first {
            case 0xFF:
                let type = try reader.readByte()
                let length = try reader.readVariableLengthQuantity()
                let payload = try reader.readBytes(length)
                handleMeta(type: type, payload: payload, tick: tick, track: &track)
                if type == 0x2F { reader.skipToEnd() }

            case 0xF0, 0xF7:
                let length = try reader.readVariableLengthQuantity()
                try reader.skip(length)

            case 0xF1...0xFE:
                throw MIDIParseError.invalidStatusByte(first)

            default:
                let status: UInt8
                var firstData: UInt8
                if first & 0x80 != 0 {
                    status = first
                    runningStatus = first
                    firstData = try reader.readByte()
                } else {
                    guard let running = runningStatus else { throw MIDIParseError.missingRunningStatus }
                    status = running
                    firstData = first
                }
                firstData &= 0x7F

                let kind = status & 0xF0
                let channel = status & 0x0F
                let secondData: UInt8 = (kind == 0xC0 || kind == 0xD0) ? 0 : (try reader.readByte()) & 0x7F
                let key = SoundingKey(channel: channel, pitch: firstData)

                if kind == 0x90 && secondData > 0 {
                    sounding[key, default: []].append(SoundingNote(startTick: tick, velocity: secondData))
                } else if kind == 0x80 || kind == 0x90 {
                    // Overlapping notes of one pitch close first-in, first-out.
                    if let started = sounding[key]?.first {
                        sounding[key]?.removeFirst()
                        track.notes.append(RawNote(
                            pitch: firstData,
                            velocity: started.velocity,
                            channel: channel,
                            startTick: started.startTick,
                            endTick: tick
                        ))
                    }
                }
            }
        }

        // Notes never released ring until the end of their track.
        for (key, unterminated) in sounding {
            for started in unterminated {
                track.notes.append(RawNote(
                    pitch: key.pitch,
                    velocity: started.velocity,
                    channel: key.channel,
                    startTick: started.startTick,
                    endTick: max(tick, started.startTick)
                ))
            }
        }
        track.notes.sort { ($0.startTick, $0.pitch) < ($1.startTick, $1.pitch) }
        return track
    }

    private static func handleMeta(type: UInt8, payload: [UInt8], tick: Int, track: inout ParsedTrack) {
        switch type {
        case 0x03:
            let name = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if track.name == nil && !name.isEmpty { track.name = name }
        case 0x51 where payload.count == 3:
            let microseconds = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
            if microseconds > 0 {
                track.tempoChanges.append(TempoChange(tick: tick, microsecondsPerQuarter: microseconds))
            }
        case 0x58 where payload.count >= 2 && payload[1] < 8 && payload[0] > 0:
            track.timeSignatures.append(RawTimeSignature(
                tick: tick,
                numerator: Int(payload[0]),
                denominator: 1 << Int(payload[1])
            ))
        default:
            break
        }
    }

    private static func barStarts(
        timeSignatures: [TimeSignatureEvent],
        timing: TickTiming,
        lastTick: Int,
        tempoMap: TempoMap
    ) -> [TimeInterval] {
        guard case .ticksPerQuarter(let ticksPerQuarter) = timing else { return [] }

        var bars: [TimeInterval] = []
        var tick = 0
        var numerator = 4
        var denominator = 4
        var nextSignature = 0

        while tick <= lastTick {
            while nextSignature < timeSignatures.count, timeSignatures[nextSignature].tick <= tick {
                numerator = timeSignatures[nextSignature].numerator
                denominator = timeSignatures[nextSignature].denominator
                nextSignature += 1
            }
            bars.append(tempoMap.seconds(atTick: tick))
            tick += max(1, ticksPerQuarter * 4 * numerator / denominator)
        }
        return bars
    }
}

// MARK: - Parsing support types

private struct RawNote {
    let pitch: UInt8
    let velocity: UInt8
    let channel: UInt8
    let startTick: Int
    let endTick: Int
}

private struct RawTimeSignature {
    let tick: Int
    let numerator: Int
    let denominator: Int
}

private struct ParsedTrack {
    var name: String?
    var notes: [RawNote] = []
    var tempoChanges: [TempoChange] = []
    var timeSignatures: [RawTimeSignature] = []
}

private struct SoundingKey: Hashable {
    let channel: UInt8
    let pitch: UInt8
}

private struct SoundingNote {
    let startTick: Int
    let velocity: UInt8
}

/// Assigns notes to hands: by average pitch across note tracks, or around middle C if there is
/// only one note track or the tracks cannot be told apart.
private struct HandAssigner {
    private let handsByTrack: [Int: Hand]

    init(tracks: [[RawNote]]) {
        var averages: [Int: Double] = [:]
        for (index, notes) in tracks.enumerated() where !notes.isEmpty {
            averages[index] = Double(notes.reduce(0) { $0 + Int($1.pitch) }) / Double(notes.count)
        }

        guard averages.count >= 2,
              let high = averages.values.max(),
              let low = averages.values.min(),
              high > low
        else {
            handsByTrack = [:]
            return
        }

        let midpoint = (high + low) / 2
        handsByTrack = averages.mapValues { $0 >= midpoint ? .right : .left }
    }

    func hand(forTrack track: Int, pitch: UInt8) -> Hand {
        handsByTrack[track] ?? (pitch >= MIDINote.middleC ? .right : .left)
    }
}
