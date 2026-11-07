import AVFoundation
import os

/// Plays piano notes through `AVAudioEngine` using additive synthesis. iOS has no built-in
/// SoundFont for `AVAudioUnitSampler`, and this way the app has no large sample assets to ship.
public final class PianoSynth: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let bank: OSAllocatedUnfairLock<PianoVoiceBank>
    private let sourceNode: AVAudioSourceNode
    private let lock = NSLock()
    private var observer: (any NSObjectProtocol)?

    public init() {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let resolvedRate = sampleRate > 0 ? sampleRate : 44_100
        let bank = OSAllocatedUnfairLock(initialState: PianoVoiceBank(sampleRate: resolvedRate))
        self.bank = bank

        sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let channel = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            // The lock's closure runs synchronously on this thread.
            nonisolated(unsafe) let first = channel

            let frames = Int(frameCount)
            // The audio thread must never block, so it renders silence if a note is being started.
            let rendered: Void? = bank.withLockIfAvailable { state in
                state.render(into: first, frameCount: frames)
            }
            if rendered == nil {
                for frame in 0..<frames { first[frame] = 0 }
            }

            for buffer in buffers.dropFirst() {
                guard let channel = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                channel.update(from: first, count: frames)
            }
            return noErr
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: resolvedRate, channels: 1) else {
            preconditionFailure("Could not create the synthesizer audio format.")
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            try? self?.start()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        engine.stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        engine.stop()
    }

    public func noteOn(note: UInt8, velocity: UInt8 = 90, duration: TimeInterval? = nil) {
        bank.withLock { $0.noteOn(note: note, velocity: velocity, duration: duration) }
    }

    public func noteOff(note: UInt8) {
        bank.withLock { $0.noteOff(note: note) }
    }

    public func allNotesOff() {
        bank.withLock { $0.allNotesOff() }
    }
}
