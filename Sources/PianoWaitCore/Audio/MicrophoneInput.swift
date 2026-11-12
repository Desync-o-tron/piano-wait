import AVFoundation
import os

public enum MicrophoneError: Error, Equatable, LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable: "No microphone is available."
        }
    }
}

/// Captures the microphone and runs the pitch detector off the audio thread.
///
/// Deliberately not actor-isolated: `AVAudioEngine` calls the tap on its own thread, and a tap
/// closure isolated to the main actor would crash on its isolation check.
public final class MicrophoneInput: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (PitchDetectionFrameResult) -> Void

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "pianowait.pitch-detection", qos: .userInitiated)
    private let expectedNotes = OSAllocatedUnfairLock(initialState: Set<UInt8>())
    private let noiseGate: OSAllocatedUnfairLock<Float>
    private let tracksLiveTuning: OSAllocatedUnfairLock<Bool>
    private let onsetRiseRatio: OSAllocatedUnfairLock<Float>
    private let onsetFallRatio: OSAllocatedUnfairLock<Float>
    private let otaDSPOverride = OSAllocatedUnfairLock<OTAConfiguration.DSP?>(initialState: nil)
    private let audioRingBuffer = OSAllocatedUnfairLock<(samples: [Float], sampleRate: Double)>(
        initialState: ([], 44100)
    )

    // Accessed only on `queue`.
    private let detector: AcousticPitchDetector
    private var assembler: AudioFrameAssembler

    private var isRunning = false
    private var observer: (any NSObjectProtocol)?

    public init(configuration: AcousticPitchDetector.Configuration = .init()) {
        detector = AcousticPitchDetector(configuration: configuration)
        assembler = AudioFrameAssembler(frameSize: configuration.frameSize)
        noiseGate = OSAllocatedUnfairLock(initialState: configuration.noiseGateRMS)
        tracksLiveTuning = OSAllocatedUnfairLock(initialState: true)
        onsetRiseRatio = OSAllocatedUnfairLock(initialState: configuration.onsetRiseRatio)
        onsetFallRatio = OSAllocatedUnfairLock(initialState: configuration.onsetFallRatio)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func setExpectedNotes(_ notes: Set<UInt8>) {
        expectedNotes.withLock { $0 = notes }
    }

    public func setNoiseGate(_ rms: Float) {
        noiseGate.withLock { $0 = rms }
    }

    public func setTracksLiveTuning(_ enabled: Bool) {
        tracksLiveTuning.withLock { $0 = enabled }
    }

    public func setOnsetSensitivity(riseRatio: Float, fallRatio: Float) {
        onsetRiseRatio.withLock { $0 = riseRatio }
        onsetFallRatio.withLock { $0 = fallRatio }
    }

    public func applyOTADSP(_ dsp: OTAConfiguration.DSP?) {
        otaDSPOverride.withLock { $0 = dsp }
        if let dsp {
            if let v = dsp.noiseGateRMS { noiseGate.withLock { $0 = v } }
            if let v = dsp.tracksLiveTuning { tracksLiveTuning.withLock { $0 = v } }
            if let v = dsp.onsetRiseRatio { onsetRiseRatio.withLock { $0 = v } }
            if let v = dsp.onsetFallRatio { onsetFallRatio.withLock { $0 = v } }
        }
    }

    public func clearRecentAudio() {
        audioRingBuffer.withLock { state in
            state.samples.removeAll(keepingCapacity: true)
        }
    }

    public func snapshotRecentAudio(maxSeconds: Double = 3.5) -> (samples: [Float], sampleRate: Double) {
        audioRingBuffer.withLock { state in
            let maxSamples = max(1, Int(state.sampleRate * maxSeconds))
            let slice = state.samples.suffix(maxSamples)
            return (Array(slice), state.sampleRate)
        }
    }

    public func start(onFrame: @escaping FrameHandler) throws {
        guard !isRunning else { return }

        try installTap(onFrame: onFrame)
        engine.prepare()
        try engine.start()
        isRunning = true

        // A route change, such as plugging in headphones, stops the engine and changes the format.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.installTap(onFrame: onFrame)
            self.engine.prepare()
            try? self.engine.start()
        }
    }

    /// Restarts capture after an interruption, such as a phone call, stopped the engine.
    public func resumeIfNeeded() throws {
        guard isRunning, !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.async { [self] in
            detector.reset()
            assembler.reset()
        }
    }

    private func installTap(onFrame: @escaping FrameHandler) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.unavailable }

        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self.queue.async {
                self.process(samples, sampleRate: sampleRate, onFrame: onFrame)
            }
        }
    }

    private func process(_ samples: [Float], sampleRate: Double, onFrame: FrameHandler) {
        audioRingBuffer.withLock { state in
            state.sampleRate = sampleRate
            state.samples.append(contentsOf: samples)
            let maxSamples = max(44_100, Int(sampleRate * 4.0))
            if state.samples.count > maxSamples {
                state.samples.removeFirst(state.samples.count - maxSamples)
            }
        }
        let frames = assembler.append(samples)
        for frame in frames {
            if let ota = otaDSPOverride.withLock({ $0 }) {
                ota.apply(to: &detector.configuration)
            }
            detector.configuration.noiseGateRMS = noiseGate.withLock { $0 }
            detector.configuration.tracksLiveTuning = tracksLiveTuning.withLock { $0 }
            detector.configuration.onsetRiseRatio = onsetRiseRatio.withLock { $0 }
            detector.configuration.onsetFallRatio = onsetFallRatio.withLock { $0 }
            let expected = expectedNotes.withLock { $0 }
            onFrame(detector.processAudioBuffer(samples: frame, sampleRate: sampleRate, expectedNotes: expected))
        }
    }
}
