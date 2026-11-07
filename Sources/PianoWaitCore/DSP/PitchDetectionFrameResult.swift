import Foundation

/// The outcome of analyzing one audio frame.
public struct PitchDetectionFrameResult: Sendable, Equatable {
    public let rms: Float
    public let isAboveNoiseGate: Bool
    /// Expected notes confirmed for the required number of consecutive frames.
    public let matchedExpectedNotes: Set<UInt8>
    /// Notes confirmed for the required number of consecutive frames that stand on their own.
    public let activeNotes: Set<UInt8>
    /// `activeNotes` plus notes whose partials are mostly shared with other notes. Any of these
    /// may really be sounding, so they count for expected notes but not for wrong notes.
    public let soundingNotes: Set<UInt8>
    /// Notes that were newly struck in this frame: just confirmed, or re-struck while ringing.
    public let onsets: Set<UInt8>
    /// Notes with spectral evidence in this frame alone, before debouncing.
    public let rawNotes: Set<UInt8>
    /// Estimated tuning offset of the piano in cents relative to 440 Hz.
    public let tuningOffsetCents: Double
    /// Top spectral peaks in the frame for telemetry and diagnostics.
    public let topPeaks: [SpectralPeak]
    public let allExpectedMatched: Bool

    public init(
        rms: Float,
        isAboveNoiseGate: Bool,
        matchedExpectedNotes: Set<UInt8>,
        activeNotes: Set<UInt8>,
        soundingNotes: Set<UInt8>,
        onsets: Set<UInt8>,
        rawNotes: Set<UInt8>,
        tuningOffsetCents: Double = 0,
        topPeaks: [SpectralPeak] = [],
        allExpectedMatched: Bool
    ) {
        self.rms = rms
        self.isAboveNoiseGate = isAboveNoiseGate
        self.matchedExpectedNotes = matchedExpectedNotes
        self.activeNotes = activeNotes
        self.soundingNotes = soundingNotes
        self.onsets = onsets
        self.rawNotes = rawNotes
        self.tuningOffsetCents = tuningOffsetCents
        self.topPeaks = topPeaks
        self.allExpectedMatched = allExpectedMatched
    }

    public static let silent = PitchDetectionFrameResult(
        rms: 0,
        isAboveNoiseGate: false,
        matchedExpectedNotes: [],
        activeNotes: [],
        soundingNotes: [],
        onsets: [],
        rawNotes: [],
        tuningOffsetCents: 0,
        topPeaks: [],
        allExpectedMatched: false
    )
}
