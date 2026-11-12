import PianoWaitCore
import SwiftUI

/// The live microphone level with an adjustable noise gate and an opt-in toggle to share
/// anonymized mic & note snippets for improving the acoustic piano pitch detector.
struct MicrophoneControl: View {
    private static let gateRange: ClosedRange<Double> = -70 ... -20

    @Bindable var session: PracticeSession
    @State private var gateDecibels = -58.4
    @State private var isShowingSettings = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isShowingSettings = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: iconName)
                        .foregroundStyle(iconStyle)
                    if session.isSharingMicTelemetry {
                        Image(systemName: "waveform.badge.plus")
                            .font(.caption2)
                            .foregroundStyle(.mint)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(statusLabel)
            .accessibilityIdentifier("microphoneSettings")
            .popover(isPresented: $isShowingSettings) {
                MicrophoneSettingsPopover(session: session, gateDecibels: $gateDecibels)
                    .presentationCompactAdaptation(.popover)
            }

            VStack(spacing: 4) {
                levelMeter
                Slider(value: $gateDecibels, in: Self.gateRange) {
                    Text("Microphone gate")
                }
                .controlSize(.mini)
                .accessibilityValue("\(Int(gateDecibels)) decibels")
            }
            .frame(width: 120)
        }
        .onChange(of: gateDecibels) { _, newValue in
            session.noiseGate = Float(pow(10, newValue / 20))
        }
    }

    private var levelMeter: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: bounds, cornerRadius: 2), with: .color(.secondary.opacity(0.3)))

            let level = fraction(forDecibels: decibels(session.microphoneLevel))
            let filled = CGRect(x: 0, y: 0, width: size.width * level, height: size.height)
            let isOpen = decibels(session.microphoneLevel) >= gateDecibels
            context.fill(Path(roundedRect: filled, cornerRadius: 2), with: .color(isOpen ? .green : .gray))

            let gateX = size.width * fraction(forDecibels: gateDecibels)
            context.fill(Path(CGRect(x: gateX - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func decibels(_ rms: Float) -> Double {
        20 * log10(max(Double(rms), 1e-5))
    }

    private func fraction(forDecibels value: Double) -> Double {
        let span = Self.gateRange.upperBound - Self.gateRange.lowerBound
        return min(max((value - Self.gateRange.lowerBound) / span, 0), 1)
    }

    private var iconName: String {
        session.microphoneStatus == .listening ? "mic.fill" : "mic.slash.fill"
    }

    private var iconStyle: Color {
        session.microphoneStatus == .listening ? .green : .secondary
    }

    private var statusLabel: String {
        switch session.microphoneStatus {
        case .off: "Microphone off"
        case .listening: "Microphone listening"
        case .denied: "Microphone access denied"
        case .unavailable(let reason): "Microphone unavailable: \(reason)"
        }
    }
}

private struct MicrophoneSettingsPopover: View {
    @Bindable var session: PracticeSession
    @Binding var gateDecibels: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Microphone & Pitch AI")
                .font(.headline)

            Toggle(isOn: $session.isSharingMicTelemetry) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Help Improve Mic Detection")
                        .font(.subheadline.weight(.medium))
                    Text("Share anonymized piano audio snippets & note accuracy data so we can train a better microphone algorithm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("shareMicTelemetryToggle")

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Noise Gate: \(Int(gateDecibels)) dB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: $gateDecibels, in: -70 ... -20)
            }
        }
        .padding()
        .frame(width: 290)
    }
}
