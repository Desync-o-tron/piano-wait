import Foundation

/// Detects acoustic piano notes in microphone audio.
///
/// The detector has no dependency on audio hardware: feed it sample buffers through
/// `processAudioBuffer`. It keeps per-note state between calls for debouncing and onset detection,
/// so use one instance per audio stream and from one thread at a time.
public final class AcousticPitchDetector {
    public struct Configuration: Sendable, Equatable {
        public var frameSize = 8192
        public var fftSize = 16384
        /// Frames quieter than this RMS level are treated as silence.
        public var noiseGateRMS: Float = 0.003
        /// How many consecutive frames must contain a note before it is reported.
        public var requiredConsecutiveFrames = 2
        /// How far a ringing note's level must rise above its low point to count as re-struck.
        public var onsetRiseRatio: Float = 1.35
        /// How far a note's level must have fallen from its peak before it can be re-struck.
        public var onsetFallRatio: Float = 0.85
        public var referenceA4 = 440.0
        /// Tracks the piano's live tuning offset in cents so slightly flat or sharp pianos stay locked.
        public var tracksLiveTuning = false
        /// Minimum fundamental-to-strongest ratio for mid-range notes (>= 100 Hz).
        public var fundamentalRatio: Float = 0.1
        /// Minimum partial-to-strongest ratio for a partial to count as support.
        public var supportRatio: Float = 0.03
        /// Minimum note-strongest-to-frame-strongest salience ratio.
        public var minimumSalience: Float = 0.06
        /// Share of a partial's amplitude that must exceed overtone predictions to count as unexplained.
        public var unexplainedShare: Float = 0.25
        /// Headroom multiplier on the fundamental of an upper note sitting on a high overtone (>= 3).
        public var highOvertoneFundamentalMargin: Float = 1.6
        /// Number of unexplained partials required for a note to stand on its own as unambiguous.
        public var requiredUnexplainedPartials: Int = 2

        public init() {}
    }

    private struct NoteTracker {
        var consecutiveFrames = 0
        var unambiguousFrames = 0
        var peakLevel: Float = 0
        var troughLevel: Float = 0
    }

    public var configuration: Configuration {
        didSet {
            evaluator.fundamentalRatio = configuration.fundamentalRatio
            evaluator.supportRatio = configuration.supportRatio
            evaluator.minimumSalience = configuration.minimumSalience
            evaluator.unexplainedShare = configuration.unexplainedShare
            evaluator.highOvertoneFundamentalMargin = configuration.highOvertoneFundamentalMargin
            evaluator.requiredUnexplainedPartials = configuration.requiredUnexplainedPartials
        }
    }
    public private(set) var estimatedTuningCents: Double = 0

    private let analyzer: SpectrumAnalyzer
    private var evaluator: HarmonicNoteEvaluator
    private var trackers: [UInt8: NoteTracker] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        analyzer = SpectrumAnalyzer(frameSize: configuration.frameSize, fftSize: configuration.fftSize)
        evaluator = HarmonicNoteEvaluator(
            referenceA4: configuration.referenceA4,
            fundamentalRatio: configuration.fundamentalRatio,
            supportRatio: configuration.supportRatio,
            minimumSalience: configuration.minimumSalience,
            unexplainedShare: configuration.unexplainedShare,
            highOvertoneFundamentalMargin: configuration.highOvertoneFundamentalMargin,
            requiredUnexplainedPartials: configuration.requiredUnexplainedPartials
        )
    }

    public func reset() {
        trackers.removeAll()
        estimatedTuningCents = 0
    }

    /// Analyzes one frame and updates the debounce state. Buffers longer than the frame size use
    /// their newest samples; shorter ones are padded with silence.
    public func processAudioBuffer(
        samples: [Float],
        sampleRate: Double,
        expectedNotes: Set<UInt8> = []
    ) -> PitchDetectionFrameResult {
        let frame = analyzer.analyze(samples: samples, sampleRate: sampleRate)
        let rms = frame.rms
        guard rms >= configuration.noiseGateRMS else {
            trackers.removeAll()
            return PitchDetectionFrameResult(
                rms: rms,
                isAboveNoiseGate: false,
                matchedExpectedNotes: [],
                activeNotes: [],
                soundingNotes: [],
                onsets: [],
                rawNotes: [],
                tuningOffsetCents: estimatedTuningCents,
                topPeaks: [],
                allExpectedMatched: false
            )
        }

        let topPeaks = Array(frame.peaks.sorted { $0.amplitude > $1.amplitude }.prefix(8))

        // An attack smears the spectrum, so it neither adds evidence nor removes notes in progress.
        if frame.isAttackTransient {
            let required = configuration.requiredConsecutiveFrames
            let sounding = Set(trackers.filter { $0.value.consecutiveFrames >= required }.keys)
            let active = Set(trackers.filter { $0.value.unambiguousFrames >= required }.keys)
            let matched = sounding.intersection(expectedNotes)
            return PitchDetectionFrameResult(
                rms: rms,
                isAboveNoiseGate: true,
                matchedExpectedNotes: matched,
                activeNotes: active,
                soundingNotes: sounding,
                onsets: [],
                rawNotes: [],
                tuningOffsetCents: estimatedTuningCents,
                topPeaks: topPeaks,
                allExpectedMatched: !expectedNotes.isEmpty && matched == expectedNotes
            )
        }

        let tuningScale = configuration.tracksLiveTuning ? pow(2.0, estimatedTuningCents / 1200.0) : 1.0
        let evaluation = evaluator.evaluate(
            frame: frame,
            sampleRate: sampleRate,
            tuningScale: tuningScale,
            expectedNotes: expectedNotes
        )
        let evidence = evaluation.evidence
        if let observedCents = evaluation.observedCents {
            let clamped = min(max(observedCents, -40), 40)
            estimatedTuningCents = estimatedTuningCents * 0.85 + clamped * 0.15
        }
        for note in trackers.keys where evidence[note] == nil {
            trackers[note] = nil
        }

        var active = Set<UInt8>()
        var sounding = Set<UInt8>()
        var onsets = Set<UInt8>()
        for (note, noteEvidence) in evidence {
            let isInChordContext = expectedNotes.count > 1 && expectedNotes.contains(note) && note < 84
            let isRelevant = noteEvidence.isUnambiguous || isInChordContext
            var tracker = trackers[note] ?? NoteTracker()
            tracker.consecutiveFrames = isRelevant ? tracker.consecutiveFrames + 1 : 0
            tracker.unambiguousFrames = noteEvidence.isUnambiguous ? tracker.unambiguousFrames + 1 : 0
            let level = noteEvidence.level

            if tracker.unambiguousFrames >= configuration.requiredConsecutiveFrames {
                active.insert(note)
            }
            if tracker.consecutiveFrames >= configuration.requiredConsecutiveFrames {
                sounding.insert(note)
                if tracker.consecutiveFrames == configuration.requiredConsecutiveFrames {
                    onsets.insert(note)
                    tracker.peakLevel = level
                    tracker.troughLevel = level
                } else {
                    tracker.troughLevel = min(tracker.troughLevel, level)
                    let hasFallen = tracker.troughLevel <= tracker.peakLevel * configuration.onsetFallRatio
                    // Without standing on its own, a rise may just be another note's overtone.
                    let isRestruck = hasFallen && level >= tracker.troughLevel * configuration.onsetRiseRatio
                    let canRestrike = noteEvidence.isUnambiguous || expectedNotes.contains(note)
                    if isRestruck && canRestrike {
                        onsets.insert(note)
                        tracker.peakLevel = level
                        tracker.troughLevel = level
                    } else if level >= tracker.peakLevel {
                        // Still climbing as the attack fills the analysis window.
                        tracker.peakLevel = level
                        tracker.troughLevel = level
                    }
                }
            }
            trackers[note] = tracker
        }

        let matched = sounding.intersection(expectedNotes)
        let candidates = evaluation.candidateRecords.map { record in
            EvaluatedCandidateRecord(
                pitch: record.pitch,
                noteName: record.noteName,
                level: record.level,
                isPlausible: record.isPlausible,
                isUnambiguous: record.isUnambiguous,
                exceedsOvertones: record.exceedsOvertones,
                isExpected: record.isExpected,
                isMatched: matched.contains(record.pitch),
                supportCount: record.supportCount,
                unexplainedPartialsCount: record.unexplainedPartialsCount,
                partialEnergies: record.partialEnergies
            )
        }
        return PitchDetectionFrameResult(
            rms: rms,
            isAboveNoiseGate: true,
            matchedExpectedNotes: matched,
            activeNotes: active,
            soundingNotes: sounding,
            onsets: onsets,
            rawNotes: Set(evidence.filter(\.value.isUnambiguous).keys),
            tuningOffsetCents: estimatedTuningCents,
            topPeaks: topPeaks,
            evaluatedCandidates: candidates,
            allExpectedMatched: !expectedNotes.isEmpty && matched == expectedNotes
        )
    }

    /// Targeted verification: which of the expected notes does this frame contain? This accepts an
    /// expected note whose partials are mostly shared with other notes, such as the upper note of
    /// an octave. Stateless, so it does not apply the consecutive-frame debounce.
    public func detectExpectedNotes(
        samples: [Float],
        sampleRate: Double,
        expectedNotes: Set<UInt8>
    ) -> Set<UInt8> {
        Set(evidence(samples: samples, sampleRate: sampleRate).keys).intersection(expectedNotes)
    }

    /// Unconstrained detection: which notes does this frame contain? Only reports notes that stand
    /// on their own. Stateless, so it does not apply the consecutive-frame debounce.
    public func detectActiveNotes(samples: [Float], sampleRate: Double) -> Set<UInt8> {
        Set(evidence(samples: samples, sampleRate: sampleRate).filter(\.value.isUnambiguous).keys)
    }

    private func evidence(samples: [Float], sampleRate: Double) -> [UInt8: HarmonicNoteEvaluator.Evidence] {
        let frame = analyzer.analyze(samples: samples, sampleRate: sampleRate)
        guard frame.rms >= configuration.noiseGateRMS, !frame.isAttackTransient else { return [:] }
        let tuningScale = configuration.tracksLiveTuning ? pow(2.0, estimatedTuningCents / 1200.0) : 1.0
        return evaluator.evaluate(frame: frame, sampleRate: sampleRate, tuningScale: tuningScale).evidence
    }
}
