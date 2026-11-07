import Foundation

/// Helpers for MIDI note numbers on the 88-key piano (A0 = 21 ... C8 = 108).
public enum MIDINote {
    public static let pianoRange: ClosedRange<UInt8> = 21...108
    public static let middleC: UInt8 = 60

    private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    public static func frequency(_ note: UInt8, a4: Double = 440) -> Double {
        a4 * pow(2, (Double(note) - 69) / 12)
    }

    public static func name(_ note: UInt8) -> String {
        "\(sharpNames[Int(note) % 12])\(Int(note) / 12 - 1)"
    }

    public static func isBlackKey(_ note: UInt8) -> Bool {
        [1, 3, 6, 8, 10].contains(Int(note) % 12)
    }

    /// Parses scientific pitch notation such as `C4`, `F#5`, or `Bb3`.
    public static func parse(_ text: String) -> UInt8? {
        var characters = Substring(text)
        guard let letter = characters.popFirst(),
              let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(letter)]
        else { return nil }

        var semitone = base
        if characters.first == "#" {
            semitone += 1
            characters.removeFirst()
        } else if characters.first == "b" {
            semitone -= 1
            characters.removeFirst()
        }

        guard let octave = Int(characters) else { return nil }
        let value = (octave + 1) * 12 + semitone
        return (0...127).contains(value) ? UInt8(value) : nil
    }
}
