import Foundation

/// The additive model of a piano tone, shared by the real-time synthesizer and test fixtures.
public enum PianoAudioSynthesizer {
    public struct Partial: Sendable, Equatable {
        /// Frequency in Hz, including the stiff-string stretch.
        public let frequency: Double
        public let amplitude: Double
        public let fastDecay: Double
        public let slowDecay: Double
    }

    /// A fundamental plus six harmonics.
    public static let partialCount = 7
    public static let attackSeconds = 0.004
    /// Share of a partial's level in the fast initial decay of a struck string.
    private static let fastDecayShare = 0.6

    /// The partials of a note. Low notes have a weak fundamental, as real bass strings do.
    public static func partials(
        note: UInt8,
        velocity: UInt8 = 90,
        inharmonicityScale: Double = 0.8,
        detuneCents: Double = 0,
        a4: Double = 440
    ) -> [Partial] {
        let fundamental = MIDINote.frequency(note, a4: a4) * pow(2, detuneCents / 1200)
        let loudness = pow(Double(velocity) / 127, 1.5)
        let inharmonicity = stringInharmonicity(note: note) * inharmonicityScale
        let normalization = (1 + inharmonicity).squareRoot()
        // Harder strikes are brighter.
        let rolloff = 1.45 - 0.45 * Double(velocity) / 127

        return (1...partialCount).map { number in
            let k = Double(number)
            var amplitude = loudness / pow(k, rolloff)
            if number == 1 && fundamental < 110 { amplitude *= 0.35 + 0.65 * max(0, fundamental - 40) / 70 }
            let slowDecay = min(6, 3.0 * pow(261.6 / fundamental, 0.5)) / pow(k, 0.5)
            return Partial(
                frequency: k * fundamental * (1 + inharmonicity * k * k).squareRoot() / normalization,
                amplitude: amplitude,
                fastDecay: slowDecay * 0.15,
                slowDecay: slowDecay
            )
        }
    }

    /// Renders one struck note with no noise. The same seed gives the same partial phases.
    public static func renderNote(
        note: UInt8,
        velocity: UInt8 = 90,
        duration: TimeInterval,
        sampleRate: Double,
        inharmonicityScale: Double = 0.8,
        detuneCents: Double = 0,
        phaseSeed: UInt64 = 1
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        guard count > 0 else { return [] }

        var output = [Float](repeating: 0, count: count)
        var generator = SeededGenerator(seed: phaseSeed &+ UInt64(note) &* 131)
        let attackSamples = max(1, Int(attackSeconds * sampleRate))

        for partial in partials(
            note: note,
            velocity: velocity,
            inharmonicityScale: inharmonicityScale,
            detuneCents: detuneCents
        ) where partial.frequency < sampleRate / 2 {
            let phase = Double.random(in: 0..<(2 * .pi), using: &generator)
            let phaseStep = 2 * Double.pi * partial.frequency / sampleRate
            let fastStep = exp(-1 / (partial.fastDecay * sampleRate))
            let slowStep = exp(-1 / (partial.slowDecay * sampleRate))
            var fast = partial.amplitude * fastDecayShare
            var slow = partial.amplitude * (1 - fastDecayShare)

            for index in 0..<count {
                let attack = index < attackSamples ? Double(index) / Double(attackSamples) : 1
                output[index] += Float(attack * (fast + slow) * sin(phase + phaseStep * Double(index)))
                fast *= fastStep
                slow *= slowStep
            }
        }
        return output
    }

    /// How much a note's strings stretch its partials sharp, rising steeply in the treble.
    public static func stringInharmonicity(note: UInt8) -> Double {
        max(0.00015, 0.0004 * pow(10, (Double(note) - 60) / 30))
    }
}

/// A small deterministic generator (SplitMix64) for reproducible audio.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
