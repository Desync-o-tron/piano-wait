import PianoWaitCore
import SwiftUI

struct PracticeControlBar: View {
    @Bindable var session: PracticeSession
    @State private var isShowingSpeed = false
    @State private var isShowingZoom = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            if verticalSizeClass == .compact {
                // Landscape has the width for one row, and no height for two.
                controlRow {
                    backButton
                    divider
                    primaryControls
                    divider
                    secondaryControls
                }
            } else {
                controlRow { primaryControls }
                controlRow { secondaryControls }
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private func controlRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, verticalSizeClass == .compact ? 4 : 6)
        }
        .scrollIndicators(.hidden)
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.subheadline.weight(.bold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.1), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("backToLibrary")
    }

    @ViewBuilder
    private var primaryControls: some View {
        transportControls
        divider
        waitToggle
        divider
        speedControl
        zoomControl
    }

    @ViewBuilder
    private var secondaryControls: some View {
        handPicker
        divider
        loopControls
        divider
        MicrophoneControl(session: session)
    }

    private var divider: some View {
        Divider().frame(height: 22).opacity(0.4)
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            Button(
                session.isPlaying ? "Pause" : "Play",
                systemImage: session.isPlaying ? "pause.fill" : "play.fill",
                action: session.togglePlayback
            )
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .accessibilityIdentifier("playPause")

            Button("Restart", systemImage: "backward.end.fill", action: session.restart)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))

            Button("Skip Step", systemImage: "forward.frame.fill", action: session.skipStep)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .disabled(!session.isWaitMode || session.state == .finished)
                .accessibilityIdentifier("skipStep")
        }
    }

    private var waitToggle: some View {
        Toggle("Wait for Me", isOn: $session.isWaitMode)
            .toggleStyle(.button)
            .buttonBorderShape(.capsule)
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("waitForMe")
    }

    private var speedControl: some View {
        Button {
            isShowingSpeed = true
        } label: {
            Label {
                Text("\(session.speed, format: .number.precision(.fractionLength(2)))x")
            } icon: {
                Image(systemName: "speedometer")
            }
            .font(.subheadline.monospacedDigit().weight(.medium))
        }
        .accessibilityLabel("Speed")
        .accessibilityValue("\(Int((session.speed * 100).rounded())) percent")
        .accessibilityIdentifier("speed")
        .popover(isPresented: $isShowingSpeed) {
            SpeedPopover(speed: $session.speed)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var zoomControl: some View {
        Button("Zoom", systemImage: "plus.magnifyingglass") {
            isShowingZoom = true
        }
        .labelStyle(.iconOnly)
        .font(.subheadline.weight(.medium))
        .accessibilityValue(zoomSummary)
        .accessibilityIdentifier("zoom")
        .popover(isPresented: $isShowingZoom) {
            ZoomPopover(zoom: $session.zoom)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var zoomSummary: String {
        let notes = session.zoom.keyboard.visibleNotes
        let seconds = session.zoom.lookaheadSeconds.formatted(.number.precision(.fractionLength(0...1)))
        return "\(notes.count) keys from \(MIDINote.name(notes.lowerBound)) to \(MIDINote.name(notes.upperBound)), \(seconds) seconds ahead"
    }

    private var handPicker: some View {
        HStack(spacing: 8) {
            Picker("Hands", selection: $session.handSelection) {
                Text("Both").tag(HandSelection.both)
                Text("Right").tag(HandSelection.right)
                Text("Left").tag(HandSelection.left)
            }
            .pickerStyle(.segmented)
            .frame(width: 148)
            .accessibilityIdentifier("hands")

            if session.handSelection != .both {
                Toggle("Auto-play other hand", systemImage: "music.quarternote.3", isOn: $session.autoPlayAccompaniment)
                    .labelStyle(.iconOnly)
                    .toggleStyle(.button)
                    .buttonBorderShape(.circle)
            }
            if !session.isWaitMode {
                Toggle("Reference audio", systemImage: "speaker.wave.2", isOn: $session.playsReferenceAudio)
                    .labelStyle(.iconOnly)
                    .toggleStyle(.button)
                    .buttonBorderShape(.circle)
            }
        }
    }

    private var loopControls: some View {
        HStack(spacing: 6) {
            Button("A", action: session.markLoopStart)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .tint(session.loopStart == nil ? .secondary : PracticePalette.expected)
                .accessibilityLabel("Set loop start")
                .accessibilityIdentifier("loopA")

            Button("B", action: session.markLoopEnd)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .tint(session.loopEnd == nil ? .secondary : PracticePalette.expected)
                .disabled(session.loopStart == nil)
                .accessibilityLabel("Set loop end")
                .accessibilityIdentifier("loopB")

            if session.loopStart != nil {
                Button("Clear Loop", systemImage: "xmark.circle.fill", action: session.clearLoop)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
