import Foundation

/// Decides which piano notes a set of spectral peaks is evidence for.
///
/// A note counts as sounding when two things are true. Its harmonic comb must be present, which
/// rejects pure tones, noise, and notes that only share overtones with what was played. And enough
/// of its partials must not be explained as overtones of other sounding notes, which rejects
/// ghosts such as C4 when C3 is played, or G3 when G2 and D4 are played together.
struct HarmonicNoteEvaluator {
    struct Evidence {
        let level: Float
        /// The note stands on its own. Otherwise its partials are mostly shared with other notes,
        /// but it has more energy than they explain, which is enough only if the song expects it.
        let isUnambiguous: Bool
    }

    /// Partials that count as evidence for a note.
    private static let evidencePartials = 8
    /// Partials looked up when predicting what a lower note contributes.
    private static let lookupPartials = 17
    private static let maximumPartialFrequency = 12_000.0
    /// Partials of one note cannot be separated from a neighboring semitone's beyond 50 cents.
    private static let toleranceRatio = 0.02
    /// Keeps low notes detectable without letting a peak match two adjacent semitones.
    private static let minimumToleranceHz = 0.8
    /// A note this far below the strongest peak is not treated as played.
    private static let minimumSalience: Float = 0.06
    /// A partial below this fraction of the note's strongest does not count as support.
    private static let supportRatio: Float = 0.03
    private static let fundamentalRatio: Float = 0.1
    private static let weakFundamentalRatio: Float = 0.03
    private static let highNoteSalience: Float = 0.25
    /// Below this frequency a phone microphone rolls off the fundamental sharply.
    private static let weakFundamentalBelowHz = 100.0
    /// Below this frequency the fundamental may not reach the microphone at all.
    private static let missingFundamentalBelowHz = 50.0
    /// Top-octave notes have so little harmonic content that one partial has to be enough.
    private static let singlePartialAboveHz = 2000.0
    /// Headroom on the partial level predicted from a lower note's neighboring partials.
    private static let ghostMargin: Float = 1.25
    /// Headroom on the tighter estimate, which starts from the weaker neighboring partial.
    private static let tightGhostMargin: Float = 1.6
    /// A partial is unexplained when this share of it exceeds what other notes predict.
    private static let unexplainedShare: Float = 0.25
    /// A real note shows up in several partials of its own. One stray partial is more likely an
    /// overtone of another chord note landing within tolerance.
    private static let requiredUnexplainedPartials = 2

    private let partialFrequencies: [Double]

    init(referenceA4: Double) {
        var table: [Double] = []
        table.reserveCapacity(128 * Self.lookupPartials)
        for note in 0..<128 {
            let fundamental = MIDINote.frequency(UInt8(note), a4: referenceA4)
            let inharmonicity = Self.inharmonicity(note: UInt8(note))
            let normalization = (1 + inharmonicity).squareRoot()
            for partial in 1...Self.lookupPartials {
                let number = Double(partial)
                table.append(number * fundamental * (1 + inharmonicity * number * number).squareRoot() / normalization)
            }
        }
        partialFrequencies = table
    }

    /// Stiff strings stretch their partials sharp: f(k) = k * f0 * sqrt(1 + B * k^2).
    static func inharmonicity(note: UInt8) -> Double {
        max(0.00015, 0.0004 * pow(10, (Double(note) - 60) / 30))
    }

    func evaluate(frame: SpectralFrame, sampleRate: Double, tuningScale: Double = 1.0) -> (evidence: [UInt8: Evidence], observedCents: Double?) {
        let strongest = frame.strongestAmplitude
        guard strongest > 0 else { return ([:], nil) }

        let limit = min(Self.maximumPartialFrequency, sampleRate * 0.45)
        var amplitudes = [Float](repeating: 0, count: 128 * Self.lookupPartials)
        for note in MIDINote.pianoRange {
            for partial in 1...Self.lookupPartials {
                let frequency = partialFrequency(note: note, partial: partial) * tuningScale
                guard frequency <= limit else { break }
                let tolerance = max(frequency * Self.toleranceRatio, Self.minimumToleranceHz)
                amplitudes[Self.index(note: note, partial: partial)] = frame.amplitude(near: frequency, tolerance: tolerance)
            }
        }

        var plausible = Set<UInt8>()
        for note in MIDINote.pianoRange where
            isPlausible(note: note, amplitudes: amplitudes, frameStrongest: strongest) {
            plausible.insert(note)
        }

        let unambiguous = resolveSoundingNotes(from: plausible, amplitudes: amplitudes)
        var evidence: [UInt8: Evidence] = [:]
        for note in plausible {
            if unambiguous.contains(note) {
                evidence[note] = Evidence(level: level(of: note, amplitudes: amplitudes), isUnambiguous: true)
            } else if exceedsOvertones(of: unambiguous, note: note, amplitudes: amplitudes) {
                evidence[note] = Evidence(level: level(of: note, amplitudes: amplitudes), isUnambiguous: false)
            }
        }

        // Measure the piano's actual tuning offset in cents (relative to referenceA4) from
        // isolated single midrange notes (C3..C6) whose fundamental peak is clean.
        var observedCents: Double?
        if unambiguous.count == 1, let note = unambiguous.first, (48...84).contains(note) {
            let nominal = partialFrequency(note: note, partial: 1)
            let searchCenter = nominal * tuningScale
            let tolerance = max(searchCenter * Self.toleranceRatio, Self.minimumToleranceHz)
            if let peak = frame.peak(near: searchCenter, tolerance: tolerance), peak.frequency > 0 {
                let cents = 1200.0 * log2(peak.frequency / nominal)
                if abs(cents) <= 45 {
                    observedCents = cents
                }
            }
        }
        return (evidence, observedCents)
    }

    // MARK: - Harmonic comb

    private func isPlausible(note: UInt8, amplitudes: [Float], frameStrongest: Float) -> Bool {
        let comb = (1...Self.evidencePartials).map { amplitudes[Self.index(note: note, partial: $0)] }
        let strongest = comb.max() ?? 0
        guard strongest >= frameStrongest * Self.minimumSalience else { return false }

        let frequency = partialFrequency(note: note, partial: 1)
        let fundamental = comb[0]
        let support = comb.filter { $0 >= strongest * Self.supportRatio }.count

        if frequency >= Self.singlePartialAboveHz {
            return fundamental >= strongest * Self.fundamentalRatio
                && (support >= 2 || fundamental >= frameStrongest * Self.highNoteSalience)
        }
        if frequency >= Self.weakFundamentalBelowHz {
            return fundamental >= strongest * Self.fundamentalRatio && support >= 2
        }
        if frequency >= Self.missingFundamentalBelowHz || fundamental >= strongest * Self.weakFundamentalRatio {
            return fundamental >= strongest * Self.weakFundamentalRatio
                && support >= 3
                && hasEnergyOffEveryHarmonicSeries(comb: comb, strongest: strongest)
        }

        // Bottom-octave notes must prove themselves with a dense series of upper partials.
        return comb[1] >= strongest * Self.fundamentalRatio
            && comb[2] >= strongest * Self.fundamentalRatio
            && support >= 4
            && hasEnergyOffEveryHarmonicSeries(comb: comb, strongest: strongest)
    }

    /// If every present partial is a multiple of m, the real note is m times higher in frequency.
    private func hasEnergyOffEveryHarmonicSeries(comb: [Float], strongest: Float) -> Bool {
        for multiple in 2...5 {
            let hasOffSeriesPartial = comb.enumerated().contains { offset, amplitude in
                (offset + 1) % multiple != 0 && amplitude >= strongest * Self.fundamentalRatio
            }
            if !hasOffSeriesPartial { return false }
        }
        return true
    }

    // MARK: - Ghost rejection

    /// Only accepted notes may explain others, or a ghost like C5 could erase the real C4 that
    /// created it. Going upward, each note is first judged against the notes below it. That can't
    /// see a higher note's overtones, so every survivor is then judged against all the others.
    private func resolveSoundingNotes(from plausible: Set<UInt8>, amplitudes: [Float]) -> Set<UInt8> {
        var accepted = Set<UInt8>()
        for note in plausible.sorted() where !isExplained(note, by: accepted, amplitudes: amplitudes) {
            accepted.insert(note)
        }
        for note in accepted.sorted(by: >) {
            var others = accepted
            others.remove(note)
            if isExplained(note, by: others, amplitudes: amplitudes) {
                accepted = others
            }
        }
        return accepted
    }

    /// A chord that doubles a note at the octave can cover nearly all of the upper note's partials,
    /// such as C4 in C3-C4-E4-G4. It still adds energy beyond what the chord's overtones would
    /// have on their own, so this estimates those overtones more tightly and asks for just that.
    /// A fundamental high on another note's overtone series, such as G4 over G2, is much stronger
    /// than that overtone when really played, so it must clear the estimate itself. If the note an
    /// octave below is sounding too, it can't, but then two of the note's partials must clear it.
    private func exceedsOvertones(of others: Set<UInt8>, note: UInt8, amplitudes: [Float]) -> Bool {
        func isUnexplained(partial: Int) -> Bool {
            let observed = amplitudes[Self.index(note: note, partial: partial)]
            guard observed > 0 else { return false }
            let frequency = partialFrequency(note: note, partial: partial)
            let predicted = others.reduce(Float(0)) { strongest, other in
                max(strongest, tightOvertoneEstimate(of: other, at: frequency, amplitudes: amplitudes))
            }
            return observed - predicted >= observed * Self.unexplainedShare
        }

        let fundamental = partialFrequency(note: note, partial: 1)
        let isDoubledAtTheOctave = note >= 12 && others.contains(note - 12)
        let isHighOnAnOvertoneSeries = others.contains { other in
            (overtoneNumber(of: other, at: fundamental) ?? 0) >= 3
        }
        if isHighOnAnOvertoneSeries {
            guard isDoubledAtTheOctave else { return isUnexplained(partial: 1) }
            return (1...Self.evidencePartials).filter(isUnexplained).count >= Self.requiredUnexplainedPartials
        }
        return (1...Self.evidencePartials).contains(where: isUnexplained)
    }

    private func isExplained(_ note: UInt8, by others: Set<UInt8>, amplitudes: [Float]) -> Bool {
        var unexplainedPartials = 0
        for partial in 1...Self.evidencePartials {
            let observed = amplitudes[Self.index(note: note, partial: partial)]
            guard observed > 0 else { continue }

            let frequency = partialFrequency(note: note, partial: partial)
            let predicted = others.reduce(Float(0)) { strongest, other in
                max(strongest, predictedOvertone(of: other, at: frequency, amplitudes: amplitudes))
            }
            if observed - predicted >= observed * Self.unexplainedShare {
                unexplainedPartials += 1
            }
        }
        return unexplainedPartials < Self.requiredUnexplainedPartials
    }

    /// What `note` alone would put at `frequency`, if one of its overtones lands there. Partial
    /// levels vary smoothly, so the neighbors of that overtone estimate it without counting energy
    /// that another note added on top. A fundamental is never treated as someone else's overtone
    /// source, because then a real note's own partials could erase the note below it.
    private func predictedOvertone(of note: UInt8, at frequency: Double, amplitudes: [Float]) -> Float {
        guard let overtone = overtoneNumber(of: note, at: frequency), overtone >= 2 else { return 0 }
        let below = amplitudes[Self.index(note: note, partial: overtone - 1)]
        let above = amplitudes[Self.index(note: note, partial: overtone + 1)]
        return max(below, above) * Self.ghostMargin
    }

    /// In a chord, either neighbor of an overtone may be inflated by another note landing on it,
    /// so the weaker one is the safer estimate. A second partial's lower neighbor is the fundamental,
    /// which is reliable, and a partial on the fundamental of `note` is simply that fundamental.
    private func tightOvertoneEstimate(of note: UInt8, at frequency: Double, amplitudes: [Float]) -> Float {
        guard let overtone = overtoneNumber(of: note, at: frequency) else { return 0 }
        if overtone == 1 {
            return amplitudes[Self.index(note: note, partial: 1)]
        }
        let below = amplitudes[Self.index(note: note, partial: overtone - 1)]
        let above = amplitudes[Self.index(note: note, partial: overtone + 1)]
        return overtone == 2 ? max(below, above) * Self.ghostMargin : min(below, above) * Self.tightGhostMargin
    }

    /// Which partial of `note` lands on `frequency`, if any.
    private func overtoneNumber(of note: UInt8, at frequency: Double) -> Int? {
        let overtone = Int((frequency / partialFrequency(note: note, partial: 1)).rounded())
        guard overtone >= 1, overtone < Self.lookupPartials else { return nil }
        let distance = abs(partialFrequency(note: note, partial: overtone) - frequency)
        return distance <= max(frequency * Self.toleranceRatio, Self.minimumToleranceHz) ? overtone : nil
    }

    /// The fundamental tracks a re-strike without reacting to overtones of other notes.
    private func level(of note: UInt8, amplitudes: [Float]) -> Float {
        let fundamental = amplitudes[Self.index(note: note, partial: 1)]
        if fundamental > 0 && partialFrequency(note: note, partial: 1) >= Self.weakFundamentalBelowHz {
            return fundamental
        }
        let energy = (1...Self.evidencePartials).reduce(Float(0)) { sum, partial in
            let amplitude = amplitudes[Self.index(note: note, partial: partial)]
            return sum + amplitude * amplitude
        }
        return energy.squareRoot()
    }

    private func partialFrequency(note: UInt8, partial: Int) -> Double {
        partialFrequencies[Self.index(note: note, partial: partial)]
    }

    private static func index(note: UInt8, partial: Int) -> Int {
        Int(note) * lookupPartials + partial - 1
    }
}
