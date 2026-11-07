import Foundation
import PianoWaitCore

/// A piano in a room. Struck notes ring and decay until their damper falls, and the microphone
/// hears the mixture of everything still sounding plus room noise. Notes from earlier steps keep
/// ringing into later ones, as they do on a real instrument.
final class SimulatedPianoRoom {
    private struct Voice {
        let note: UInt8
        let samples: [Float]
        var position = 0
        var damper: Float = 1
        var isReleased = false
    }

    private static let renderDuration: TimeInterval = 2.5
    private static let damperTime: TimeInterval = 0.07

    let sampleRate: Double

    private let noiseRMS: Float
    private let damperStep: Float
    private var voices: [Voice] = []
    private var renders: [UInt16: [Float]] = [:]
    private var noiseGenerator: SeededGenerator

    init(sampleRate: Double = 44_100, noiseRMS: Float = 0.0005, seed: UInt64 = 7) {
        self.sampleRate = sampleRate
        self.noiseRMS = noiseRMS
        damperStep = Float(exp(-1 / (Self.damperTime * sampleRate)))
        noiseGenerator = SeededGenerator(seed: seed)
    }

    var soundingNotes: Set<UInt8> {
        Set(voices.filter { !$0.isReleased }.map(\.note))
    }

    /// Strikes a note. Striking a sounding note replaces it, because the hammer restarts the string.
    func strike(_ note: UInt8, velocity: UInt8 = 90) {
        voices.removeAll { $0.note == note }
        voices.append(Voice(note: note, samples: render(note: note, velocity: velocity)))
    }

    func release(_ note: UInt8) {
        for index in voices.indices where voices[index].note == note {
            voices[index].isReleased = true
        }
    }

    func releaseAll() {
        for index in voices.indices {
            voices[index].isReleased = true
        }
    }

    /// Renders the next block of what the microphone hears.
    func nextSamples(count: Int) -> [Float] {
        let amplitude = noiseRMS * 3.0.squareRoot().asFloat
        var output = (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &noiseGenerator) }

        for voiceIndex in voices.indices {
            var voice = voices[voiceIndex]
            for sample in 0..<count where voice.position < voice.samples.count {
                if voice.isReleased { voice.damper *= damperStep }
                output[sample] += voice.samples[voice.position] * voice.damper
                voice.position += 1
            }
            voices[voiceIndex] = voice
        }
        voices.removeAll { $0.position >= $0.samples.count || $0.damper < 0.0005 }
        return output
    }

    private func render(note: UInt8, velocity: UInt8) -> [Float] {
        let key = UInt16(note) << 8 | UInt16(velocity)
        if let cached = renders[key] { return cached }
        let samples = PianoAudioSynthesizer.renderNote(
            note: note,
            velocity: velocity,
            duration: Self.renderDuration,
            sampleRate: sampleRate,
            phaseSeed: UInt64(key)
        )
        renders[key] = samples
        return samples
    }
}

private extension Double {
    var asFloat: Float { Float(self) }
}
