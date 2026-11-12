import Foundation

/// Per-candidate harmonic feature vector captured by the DSP evaluator for classifier training & telemetry.
public struct EvaluatedCandidateRecord: Sendable, Codable, Equatable {
    public let pitch: UInt8
    public let noteName: String
    public let level: Float
    public let isPlausible: Bool
    public let isUnambiguous: Bool
    public let exceedsOvertones: Bool
    public let isExpected: Bool
    public let isMatched: Bool
    public let supportCount: Int
    public let unexplainedPartialsCount: Int
    public let partialEnergies: [Float]

    public init(
        pitch: UInt8,
        noteName: String,
        level: Float,
        isPlausible: Bool,
        isUnambiguous: Bool,
        exceedsOvertones: Bool,
        isExpected: Bool,
        isMatched: Bool,
        supportCount: Int,
        unexplainedPartialsCount: Int,
        partialEnergies: [Float]
    ) {
        self.pitch = pitch
        self.noteName = noteName
        self.level = level
        self.isPlausible = isPlausible
        self.isUnambiguous = isUnambiguous
        self.exceedsOvertones = exceedsOvertones
        self.isExpected = isExpected
        self.isMatched = isMatched
        self.supportCount = supportCount
        self.unexplainedPartialsCount = unexplainedPartialsCount
        self.partialEnergies = partialEnergies
    }
}

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
    /// Full harmonic feature vectors for all plausible + expected candidates in this frame.
    public let evaluatedCandidates: [EvaluatedCandidateRecord]
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
        evaluatedCandidates: [EvaluatedCandidateRecord] = [],
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
        self.evaluatedCandidates = evaluatedCandidates
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
        evaluatedCandidates: [],
        allExpectedMatched: false
    )
}
