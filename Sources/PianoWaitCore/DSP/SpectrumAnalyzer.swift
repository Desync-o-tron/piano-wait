import Accelerate
import Foundation

public struct SpectralPeak: Sendable, Codable, Equatable {
    public let frequency: Double
    public let amplitude: Float

    public init(frequency: Double, amplitude: Float) {
        self.frequency = frequency
        self.amplitude = amplitude
    }
}

/// The spectral peaks of one frame, sorted by frequency.
struct SpectralFrame {
    let rms: Float
    let peaks: [SpectralPeak]
    /// A sound has only just entered the window, so its spectrum is smeared and unreliable.
    let isAttackTransient: Bool

    var bestPeak: SpectralPeak? {
        peaks.max(by: { $0.amplitude < $1.amplitude })
    }

    var strongestAmplitude: Float { bestPeak?.amplitude ?? 0 }

    /// The strongest peak within `tolerance` Hz of `frequency`, or nil if there is none.
    func peak(near frequency: Double, tolerance: Double) -> SpectralPeak? {
        var low = 0
        var high = peaks.count
        while low < high {
            let middle = (low + high) / 2
            if peaks[middle].frequency < frequency - tolerance {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var best: SpectralPeak?
        var index = low
        while index < peaks.count, peaks[index].frequency <= frequency + tolerance {
            if best == nil || peaks[index].amplitude > best!.amplitude {
                best = peaks[index]
            }
            index += 1
        }
        return best
    }

    /// The strongest peak within `tolerance` Hz of `frequency`, or 0 if there is none.
    func amplitude(near frequency: Double, tolerance: Double) -> Float {
        peak(near: frequency, tolerance: tolerance)?.amplitude ?? 0
    }
}

/// Hann-windowed, zero-padded FFT with noise-adaptive peak picking.
final class SpectrumAnalyzer {
    private static let minimumFrequency = 20.0
    private static let maximumFrequency = 12_000.0
    private static let noiseBandEdges: [Double] = [20, 80, 160, 320, 640, 1280, 2560, 5120, 12_000]
    /// A Rayleigh noise bin essentially never exceeds seven times the lower quartile.
    private static let noiseFloorMultiplier: Float = 7
    /// Peaks below this fraction of the strongest peak are ignored.
    private static let relativePeakThreshold: Float = 0.008
    /// Hann sidelobes sit near -31 dB, so a much weaker neighbor of a strong peak is not a partial.
    private static let sidelobeRatio: Float = 0.06
    private static let sidelobeReachInBins = 4.0
    /// How much louder the newest quarter of a frame must be than the rest to be an attack.
    private static let attackEnergyRatio: Float = 2.5

    let frameSize: Int
    let fftSize: Int

    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let windowSum: Float

    init(frameSize: Int, fftSize: Int) {
        precondition(fftSize.nonzeroBitCount == 1, "The FFT size must be a power of two.")
        precondition(frameSize <= fftSize, "The frame must fit in the FFT.")

        self.frameSize = frameSize
        self.fftSize = fftSize
        log2Size = vDSP_Length(fftSize.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Could not allocate the FFT setup.")
        }
        self.setup = setup

        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_DENORM))
        self.window = window
        windowSum = vDSP.sum(window)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func analyze(samples: [Float], sampleRate: Double) -> SpectralFrame {
        let frame = preparedFrame(samples)
        let rms = vDSP.rootMeanSquare(frame)
        let magnitudes = spectrum(frame)
        return SpectralFrame(
            rms: rms,
            peaks: pickPeaks(magnitudes, sampleRate: sampleRate),
            isAttackTransient: isAttackTransient(frame)
        )
    }

    private func isAttackTransient(_ frame: [Float]) -> Bool {
        let split = frameSize * 3 / 4
        let older = vDSP.rootMeanSquare(frame[..<split])
        let newest = vDSP.rootMeanSquare(frame[split...])
        return newest > older * Self.attackEnergyRatio
    }

    /// Fits the buffer to the frame size, keeping the newest samples and removing DC offset.
    private func preparedFrame(_ samples: [Float]) -> [Float] {
        var frame = [Float](repeating: 0, count: frameSize)
        let count = min(samples.count, frameSize)
        for offset in 0..<count {
            let sample = samples[samples.count - count + offset]
            frame[frameSize - count + offset] = sample.isFinite ? sample : 0
        }
        let mean = vDSP.mean(frame)
        return vDSP.add(-mean, frame)
    }

    /// Returns magnitudes scaled so a sine of amplitude A peaks at A.
    private func spectrum(_ frame: [Float]) -> [Float] {
        var padded = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &padded, 1, vDSP_Length(frameSize))

        let halfSize = fftSize / 2
        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                guard let realBase = realBuffer.baseAddress, let imaginaryBase = imaginaryBuffer.baseAddress else {
                    return
                }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                padded.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self)
                    guard let base = complex.baseAddress else { return }
                    vDSP_ctoz(base, 2, &split, 1, vDSP_Length(halfSize))
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Bin 0 packs DC and Nyquist together. vDSP's forward FFT is scaled by 2, which already
        // accounts for the energy in the negative frequencies.
        magnitudes[0] = 0
        return vDSP.divide(magnitudes, windowSum)
    }

    private func pickPeaks(_ magnitudes: [Float], sampleRate: Double) -> [SpectralPeak] {
        let binWidth = sampleRate / Double(fftSize)
        let lastBin = min(magnitudes.count - 2, Int(Self.maximumFrequency / binWidth))
        let firstBin = max(1, Int(Self.minimumFrequency / binWidth))
        guard firstBin < lastBin else { return [] }

        let floors = noiseFloors(magnitudes, binWidth: binWidth, lastBin: lastBin)
        let strongest = magnitudes[firstBin...lastBin].max() ?? 0
        guard strongest > 0 else { return [] }
        let relativeThreshold = strongest * Self.relativePeakThreshold

        var peaks: [SpectralPeak] = []
        for bin in firstBin...lastBin {
            let value = magnitudes[bin]
            guard value > magnitudes[bin - 1], value >= magnitudes[bin + 1],
                  value >= relativeThreshold, value >= floors[bin]
            else { continue }

            // Parabolic interpolation over log magnitude is very accurate for a Hann main lobe.
            let left = log(max(magnitudes[bin - 1], .leastNormalMagnitude))
            let center = log(value)
            let right = log(max(magnitudes[bin + 1], .leastNormalMagnitude))
            let denominator = left - 2 * center + right
            let offset = denominator == 0 ? 0 : 0.5 * (left - right) / denominator
            let amplitude = exp(center - 0.25 * (left - right) * offset)
            peaks.append(SpectralPeak(
                frequency: (Double(bin) + Double(offset)) * binWidth,
                amplitude: amplitude
            ))
        }
        return removingSidelobes(peaks, sampleRate: sampleRate)
    }

    private func noiseFloors(_ magnitudes: [Float], binWidth: Double, lastBin: Int) -> [Float] {
        var floors = [Float](repeating: .greatestFiniteMagnitude, count: lastBin + 2)
        for (lower, upper) in zip(Self.noiseBandEdges, Self.noiseBandEdges.dropFirst()) {
            let start = max(1, Int(lower / binWidth))
            let end = min(lastBin + 1, Int(upper / binWidth))
            guard start < end else { continue }

            var band = Array(magnitudes[start..<end])
            vDSP.sort(&band, sortOrder: .ascending)
            let floor = band[band.count / 4] * Self.noiseFloorMultiplier
            for bin in start..<end {
                floors[bin] = floor
            }
        }
        return floors
    }

    private func removingSidelobes(_ peaks: [SpectralPeak], sampleRate: Double) -> [SpectralPeak] {
        let reach = Self.sidelobeReachInBins * sampleRate / Double(frameSize)
        return peaks.enumerated().filter { index, peak in
            var neighbor = index - 1
            while neighbor >= 0, peak.frequency - peaks[neighbor].frequency <= reach {
                if peak.amplitude < peaks[neighbor].amplitude * Self.sidelobeRatio { return false }
                neighbor -= 1
            }
            neighbor = index + 1
            while neighbor < peaks.count, peaks[neighbor].frequency - peak.frequency <= reach {
                if peak.amplitude < peaks[neighbor].amplitude * Self.sidelobeRatio { return false }
                neighbor += 1
            }
            return true
        }.map(\.element)
    }
}
