import Foundation

/// Turns arbitrarily sized microphone buffers into overlapping analysis frames.
public struct AudioFrameAssembler: Sendable {
    public let frameSize: Int
    public let hopSize: Int

    private var history: [Float]
    private var pending: [Float] = []

    public init(frameSize: Int = 8192, hopSize: Int = 2048) {
        precondition(frameSize > 0 && hopSize > 0 && hopSize <= frameSize, "Invalid frame geometry.")
        self.frameSize = frameSize
        self.hopSize = hopSize
        history = [Float](repeating: 0, count: frameSize)
    }

    /// Adds samples and returns one complete frame for every full hop now available.
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var frames: [[Float]] = []
        var consumed = 0
        while pending.count - consumed >= hopSize {
            history.removeFirst(hopSize)
            history.append(contentsOf: pending[consumed..<(consumed + hopSize)])
            frames.append(history)
            consumed += hopSize
        }
        pending.removeFirst(consumed)
        return frames
    }

    public mutating func reset() {
        history = [Float](repeating: 0, count: frameSize)
        pending.removeAll(keepingCapacity: true)
    }
}
