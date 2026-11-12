import Foundation

public struct BuiltInSong: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let composer: String
    public let fileName: String
    public let midiData: Data

    public func parsed() throws -> MIDISong {
        try MIDIParser.parse(data: midiData, title: title)
    }
}

/// Starter songs embedded in the app or generated from note lists, so it works before its first sync.
public enum BuiltInSongs {
    /// Songs bundled in the app.
    public static let all: [BuiltInSong] = [darkIsTheNight, odeToJoy, minuetInG, furElise]

    /// Everything in `samples/`: the bundled songs plus extra files for the cloud bucket.
    public static let sampleFiles: [BuiltInSong] = all + [twinkle, chordDrill]

    public static let odeToJoy = BuiltInSong(
        id: "ode-to-joy",
        title: "Ode to Joy",
        composer: "Beethoven",
        fileName: "ode_to_joy.mid",
        midiData: score(
            title: "Ode to Joy",
            beatsPerMinute: 96,
            meter: (4, 4),
            right: """
            E4:1 E4:1 F4:1 G4:1 | G4:1 F4:1 E4:1 D4:1 | C4:1 C4:1 D4:1 E4:1 | E4:1.5 D4:0.5 D4:2 |
            E4:1 E4:1 F4:1 G4:1 | G4:1 F4:1 E4:1 D4:1 | C4:1 C4:1 D4:1 E4:1 | D4:1.5 C4:0.5 C4:2 |
            D4:1 D4:1 E4:1 C4:1 | D4:1 E4:0.5 F4:0.5 E4:1 C4:1 | D4:1 E4:0.5 F4:0.5 E4:1 D4:1 | C4:1 D4:1 G3:2 |
            E4:1 E4:1 F4:1 G4:1 | G4:1 F4:1 E4:1 D4:1 | C4:1 C4:1 D4:1 E4:1 | D4:1.5 C4:0.5 C4:2
            """,
            left: """
            C3:2 G3:2 | G2:2 G3:2 | C3:2 G3:2 | G2:2 G2:2 |
            C3:2 G3:2 | G2:2 G3:2 | C3:2 G3:2 | G2:2 C3:2 |
            G2:2 C3:2 | G2:2 C3:2 | G2:2 C3:2 | G2:2 G2:2 |
            C3:2 G3:2 | G2:2 G3:2 | C3:2 G3:2 | G2:2 C3:2
            """
        )
    )

    public static let minuetInG = BuiltInSong(
        id: "minuet-in-g",
        title: "Minuet in G",
        composer: "J.S. Bach (attr.)",
        fileName: "minuet_in_g.mid",
        midiData: score(
            title: "Minuet in G",
            beatsPerMinute: 108,
            meter: (3, 4),
            right: """
            D5:1 G4:0.5 A4:0.5 B4:0.5 C5:0.5 | D5:1 G4:1 G4:1 | E5:1 C5:0.5 D5:0.5 E5:0.5 F#5:0.5 | G5:1 G4:1 G4:1 |
            C5:1 D5:0.5 C5:0.5 B4:0.5 A4:0.5 | B4:1 C5:0.5 B4:0.5 A4:0.5 G4:0.5 | F#4:1 G4:0.5 A4:0.5 B4:0.5 G4:0.5 | A4:3 |
            D5:1 G4:0.5 A4:0.5 B4:0.5 C5:0.5 | D5:1 G4:1 G4:1 | E5:1 C5:0.5 D5:0.5 E5:0.5 F#5:0.5 | G5:1 G4:1 G4:1 |
            C5:1 D5:0.5 C5:0.5 B4:0.5 A4:0.5 | B4:1 C5:0.5 B4:0.5 A4:0.5 G4:0.5 | A4:1 B4:0.5 A4:0.5 G4:0.5 F#4:0.5 | G4:3
            """,
            left: """
            G3:2 A3:1 | B3:3 | C4:3 | B3:3 |
            A3:3 | G3:3 | D4:1 B3:1 G3:1 | D4:1 D3:0.5 C4:0.5 B3:0.5 A3:0.5 |
            G3:2 A3:1 | B3:3 | C4:3 | B3:3 |
            A3:3 | G3:3 | C4:1 D4:1 D3:1 | G3:2 G2:1
            """
        )
    )

    public static let furElise = BuiltInSong(
        id: "fur-elise-opening",
        title: "Für Elise (Opening)",
        composer: "Beethoven",
        fileName: "fur_elise_opening.mid",
        midiData: score(
            title: "Für Elise (Opening)",
            beatsPerMinute: 66,
            meter: (3, 8),
            right: """
            R:1 E5:0.25 D#5:0.25 |
            E5:0.25 D#5:0.25 E5:0.25 B4:0.25 D5:0.25 C5:0.25 |
            A4:0.75 C4:0.25 E4:0.25 A4:0.25 |
            B4:0.75 E4:0.25 G#4:0.25 B4:0.25 |
            C5:0.75 E4:0.25 E5:0.25 D#5:0.25 |
            E5:0.25 D#5:0.25 E5:0.25 B4:0.25 D5:0.25 C5:0.25 |
            A4:0.75 C4:0.25 E4:0.25 A4:0.25 |
            B4:0.75 E4:0.25 C5:0.25 B4:0.25 |
            A4:1.5
            """,
            left: """
            R:1.5 | R:1.5 |
            A2:0.25 E3:0.25 A3:0.25 R:0.75 |
            E2:0.25 E3:0.25 G#3:0.25 R:0.75 |
            A2:0.25 E3:0.25 A3:0.25 R:0.75 |
            R:1.5 |
            A2:0.25 E3:0.25 A3:0.25 R:0.75 |
            E2:0.25 E3:0.25 G#3:0.25 R:0.75 |
            A2:0.25 E3:0.25 A3:0.25 R:0.75
            """
        )
    )

    /// A single-track Format 0 file, which exercises the middle C hand split.
    public static let twinkle = BuiltInSong(
        id: "twinkle-twinkle",
        title: "Twinkle Twinkle Little Star",
        composer: "Traditional",
        fileName: "twinkle_twinkle.mid",
        midiData: score(
            title: "Twinkle Twinkle Little Star",
            beatsPerMinute: 100,
            meter: (4, 4),
            right: """
            C4+C3:1 C4:1 G4+E3:1 G4:1 | A4+F3:1 A4:1 G4+E3:2 |
            F4+D3:1 F4:1 E4+C3:1 E4:1 | D4+G2:1 D4:1 C4+C3:2 |
            G4+E3:1 G4:1 F4+D3:1 F4:1 | E4+C3:1 E4:1 D4+G2:2 |
            G4+E3:1 G4:1 F4+D3:1 F4:1 | E4+C3:1 E4:1 D4+G2:2 |
            C4+C3:1 C4:1 G4+E3:1 G4:1 | A4+F3:1 A4:1 G4+E3:2 |
            F4+D3:1 F4:1 E4+C3:1 E4:1 | D4+G2:1 D4:1 C4+C3:2
            """,
            left: nil
        )
    )

    /// Block chords in both hands with a tempo change halfway through.
    public static let chordDrill: BuiltInSong = {
        var right = MIDIFileBuilder.Track(name: "Chord Drill")
        right.addTempo(beatsPerMinute: 72)
        right.addTempo(beatsPerMinute: 54, tick: 480 * 16)
        right.addTimeSignature(numerator: 4, denominator: 4)
        var left = MIDIFileBuilder.Track(name: "Left Hand")

        let progression: [(right: String, left: String)] = [
            ("C4+E4+G4", "C3"), ("D4+F4+A4", "D3"), ("E4+G4+B4", "E3"), ("F4+A4+C5", "F3"),
            ("G4+B4+D5", "G3"), ("A4+C5+E5", "A3"), ("G4+B4+D5", "G3"), ("C4+E4+G4", "C3+G3"),
        ]
        for (bar, chord) in (progression + progression).enumerated() {
            let tick = bar * 480 * 2
            for pitch in pitches(chord.right) {
                right.addNote(pitch: pitch, startTick: tick, durationTicks: 900)
            }
            for pitch in pitches(chord.left) {
                left.addNote(pitch: pitch, startTick: tick, durationTicks: 900)
            }
        }
        return BuiltInSong(
            id: "chord-drill",
            title: "Chord Drill",
            composer: "PianoWait",
            fileName: "chord_drill.mid",
            midiData: MIDIFileBuilder(tracks: [right, left]).build()
        )
    }()

    // MARK: - Score notation

    private static let ticksPerQuarter = 480

    /// Builds a file from text such as `C4:1 E4+G4:0.5 R:2 |`, with durations in quarter notes.
    private static func score(
        title: String,
        beatsPerMinute: Double,
        meter: (Int, Int),
        right: String,
        left: String?
    ) -> Data {
        var rightTrack = MIDIFileBuilder.Track(name: title)
        rightTrack.addTempo(beatsPerMinute: beatsPerMinute)
        rightTrack.addTimeSignature(numerator: meter.0, denominator: meter.1)
        add(score: right, to: &rightTrack, velocity: 84)

        var tracks = [rightTrack]
        if let left {
            var leftTrack = MIDIFileBuilder.Track(name: "Left Hand")
            add(score: left, to: &leftTrack, velocity: 68)
            tracks.append(leftTrack)
        }
        return MIDIFileBuilder(ticksPerQuarter: ticksPerQuarter, tracks: tracks).build()
    }

    private static func add(score: String, to track: inout MIDIFileBuilder.Track, velocity: UInt8) {
        var tick = 0
        let tokens = score.split(whereSeparator: { $0.isWhitespace || $0 == "|" })
        for token in tokens {
            let parts = token.split(separator: ":")
            guard parts.count == 2, let beats = Double(parts[1]) else {
                preconditionFailure("Invalid score token: \(token)")
            }
            let ticks = Int((beats * Double(ticksPerQuarter)).rounded())
            if parts[0] != "R" {
                for pitch in pitches(String(parts[0])) {
                    track.addNote(pitch: pitch, startTick: tick, durationTicks: ticks, velocity: velocity)
                }
            }
            tick += ticks
        }
    }

    private static func pitches(_ text: String) -> [UInt8] {
        text.split(separator: "+").map { name in
            guard let pitch = MIDINote.parse(String(name)) else {
                preconditionFailure("Invalid note name: \(name)")
            }
            return pitch
        }
    }
}
