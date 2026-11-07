import Foundation
import PianoWaitCore

/// Synthesizes deterministic acoustic piano test signals: a fundamental plus six harmonics with
/// exponential decay and slight inharmonicity, chord mixtures, and white or pink room noise.
struct TestPianoSignalGenerator {
    static let frameSize = 8192
    static let hopSize = 2048

    let sampleRate: Double

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
    }

    func note(
        _ note: UInt8,
        velocity: UInt8 = 90,
        duration: TimeInterval = 1,
        detuneCents: Double = 0,
        seed: UInt64 = 1
    ) -> [Float] {
        PianoAudioSynthesizer.renderNote(
            note: note,
            velocity: velocity,
            duration: duration,
            sampleRate: sampleRate,
            detuneCents: detuneCents,
            phaseSeed: seed
        )
    }

    func chord(
        _ notes: [UInt8],
        velocity: UInt8 = 90,
        duration: TimeInterval = 1,
        detuneCents: Double = 0,
        seed: UInt64 = 1
    ) -> [Float] {
        var output = [Float](repeating: 0, count: Int(duration * sampleRate))
        for (index, note) in notes.enumerated() {
            let voice = self.note(
                note,
                velocity: velocity,
                duration: duration,
                detuneCents: detuneCents,
                seed: seed &+ UInt64(index) &* 17
            )
            for sample in output.indices {
                output[sample] += voice[sample]
            }
        }
        return output
    }

    /// A single sine wave, such as a whistle or a beep.
    func sine(frequency: Double, amplitude: Float = 0.3, duration: TimeInterval = 1) -> [Float] {
        (0..<Int(duration * sampleRate)).map { index in
            amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    func silence(duration: TimeInterval = 1) -> [Float] {
        [Float](repeating: 0, count: Int(duration * sampleRate))
    }

    func whiteNoise(rms: Float, duration: TimeInterval = 1, seed: UInt64 = 42) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        var samples = (0..<Int(duration * sampleRate)).map { _ in Float.random(in: -1...1, using: &generator) }
        Self.scale(&samples, toRMS: rms)
        return samples
    }

    /// Pink noise from Paul Kellet's economy filter.
    func pinkNoise(rms: Float, duration: TimeInterval = 1, seed: UInt64 = 43) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        var (b0, b1, b2): (Float, Float, Float) = (0, 0, 0)
        var samples = (0..<Int(duration * sampleRate)).map { _ -> Float in
            let white = Float.random(in: -1...1, using: &generator)
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            return b0 + b1 + b2 + white * 0.1848
        }
        Self.scale(&samples, toRMS: rms)
        return samples
    }

    /// Adds white noise at the given signal-to-noise ratio.
    func addingWhiteNoise(to signal: [Float], snrDecibels: Float, seed: UInt64 = 44) -> [Float] {
        let noiseRMS = Self.rms(signal) / pow(10, snrDecibels / 20)
        let noise = whiteNoise(rms: noiseRMS, duration: Double(signal.count) / sampleRate, seed: seed)
        return Self.mix(signal, noise)
    }

    /// One analysis frame starting `offset` seconds into the signal, clear of the hammer attack.
    func frame(of signal: [Float], at offset: TimeInterval = 0.05) -> [Float] {
        let start = Int(offset * sampleRate)
        return Array(signal[start..<(start + Self.frameSize)])
    }

    /// Consecutive overlapping frames, as the live microphone path produces.
    func frames(of signal: [Float], count: Int, startingAt offset: TimeInterval = 0.05) -> [[Float]] {
        let start = Int(offset * sampleRate)
        return (0..<count).map { index in
            let begin = start + index * Self.hopSize
            return Array(signal[begin..<(begin + Self.frameSize)])
        }
    }

    static func mix(_ first: [Float], _ second: [Float]) -> [Float] {
        let count = max(first.count, second.count)
        return (0..<count).map { index in
            (index < first.count ? first[index] : 0) + (index < second.count ? second[index] : 0)
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private static func scale(_ samples: inout [Float], toRMS target: Float) {
        let current = rms(samples)
        guard current > 0 else { return }
        for index in samples.indices {
            samples[index] *= target / current
        }
    }
}
