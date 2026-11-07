import Foundation

/// Polyphonic additive synthesis with no hardware dependency. All storage is preallocated, so
/// `render` does not allocate and can run on the audio thread.
public struct PianoVoiceBank: Sendable {
    private struct Oscillator: Sendable {
        var phase = 0.0
        var phaseStep = 0.0
        var fast = 0.0
        var slow = 0.0
        var fastStep = 1.0
        var slowStep = 1.0
    }

    private struct Voice: Sendable {
        var note: UInt8 = 0
        var isActive = false
        var isReleased = false
        var framesUntilRelease = Int.max
        var attack = 1.0
        var damper = 1.0
        var age = 0
    }

    public static let voiceCount = 16
    private static let releaseSeconds = 0.12
    private static let silenceThreshold = 0.00005
    /// Keeps a full chord from clipping.
    private static let outputGain = 0.28

    private let sampleRate: Double
    private let attackStep: Double
    private let damperStep: Double
    private var voices: [Voice]
    private var oscillators: [Oscillator]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        attackStep = 1 / max(1, PianoAudioSynthesizer.attackSeconds * sampleRate)
        damperStep = exp(-1 / (Self.releaseSeconds * sampleRate))
        voices = Array(repeating: Voice(), count: Self.voiceCount)
        oscillators = Array(repeating: Oscillator(), count: Self.voiceCount * PianoAudioSynthesizer.partialCount)
    }

    public var activeVoiceCount: Int {
        voices.reduce(0) { $0 + ($1.isActive ? 1 : 0) }
    }

    /// Starts a note, stealing the oldest voice if all are busy. With a `duration` the note
    /// releases itself; otherwise it rings until `noteOff`.
    public mutating func noteOn(note: UInt8, velocity: UInt8 = 90, duration: TimeInterval? = nil) {
        let index = voices.firstIndex { !$0.isActive } ?? oldestVoiceIndex()
        var voice = Voice()
        voice.note = note
        voice.isActive = true
        voice.attack = 0
        if let duration {
            voice.framesUntilRelease = max(1, Int(duration * sampleRate))
        }
        voices[index] = voice

        let base = index * PianoAudioSynthesizer.partialCount
        for (offset, partial) in PianoAudioSynthesizer.partials(note: note, velocity: velocity, inharmonicityScale: 1).enumerated() {
            let isAudible = partial.frequency < sampleRate / 2
            oscillators[base + offset] = Oscillator(
                phase: 0,
                phaseStep: 2 * .pi * partial.frequency / sampleRate,
                fast: isAudible ? partial.amplitude * 0.6 : 0,
                slow: isAudible ? partial.amplitude * 0.4 : 0,
                fastStep: exp(-1 / (partial.fastDecay * sampleRate)),
                slowStep: exp(-1 / (partial.slowDecay * sampleRate))
            )
        }
    }

    public mutating func noteOff(note: UInt8) {
        for index in voices.indices where voices[index].isActive && voices[index].note == note {
            voices[index].isReleased = true
        }
    }

    public mutating func allNotesOff() {
        for index in voices.indices where voices[index].isActive {
            voices[index].isReleased = true
        }
    }

    /// Mixes the next `frameCount` samples into silence-initialized `buffer`.
    public mutating func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for frame in 0..<frameCount { buffer[frame] = 0 }

        for voiceIndex in voices.indices where voices[voiceIndex].isActive {
            let base = voiceIndex * PianoAudioSynthesizer.partialCount
            var voice = voices[voiceIndex]
            var loudest = 0.0

            for frame in 0..<frameCount {
                if voice.framesUntilRelease == 0 { voice.isReleased = true }
                if voice.framesUntilRelease != .max { voice.framesUntilRelease -= 1 }
                if voice.isReleased { voice.damper *= damperStep }
                voice.attack = min(1, voice.attack + attackStep)

                var sample = 0.0
                for partial in base..<(base + PianoAudioSynthesizer.partialCount) {
                    let level = oscillators[partial].fast + oscillators[partial].slow
                    sample += level * sin(oscillators[partial].phase)
                    oscillators[partial].phase += oscillators[partial].phaseStep
                    if oscillators[partial].phase > 2 * .pi { oscillators[partial].phase -= 2 * .pi }
                    oscillators[partial].fast *= oscillators[partial].fastStep
                    oscillators[partial].slow *= oscillators[partial].slowStep
                }
                let gain = voice.attack * voice.damper
                buffer[frame] += Float(sample * gain * Self.outputGain)
                loudest = max(loudest, gain)
            }

            voice.age += frameCount
            let remaining = oscillators[base].slow + oscillators[base + 1].slow
            if voice.damper * remaining < Self.silenceThreshold || loudest < Self.silenceThreshold {
                voice.isActive = false
            }
            voices[voiceIndex] = voice
        }
    }

    private func oldestVoiceIndex() -> Int {
        var oldest = 0
        for index in voices.indices where voices[index].age > voices[oldest].age {
            oldest = index
        }
        return oldest
    }
}
