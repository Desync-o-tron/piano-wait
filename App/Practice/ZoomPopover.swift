import PianoWaitCore
import SwiftUI

struct ZoomPopover: View {
    @Binding var zoom: PracticeZoom

    var body: some View {
        VStack(spacing: 14) {
            keyZoom
            Divider()
            lookahead
        }
        .padding()
        .frame(minWidth: 320)
    }

    private var keyZoom: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Zoom Out", systemImage: "minus") { zoom.zoomOut() }
                    .labelStyle(.iconOnly)
                    .disabled(!zoom.keyboard.canZoomOut)
                    .accessibilityIdentifier("zoomOut")

                Spacer()
                Text("\(zoom.keyboard.visibleNotes.count) keys")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .accessibilityIdentifier("zoomKeys")
                Spacer()

                Button("Zoom In", systemImage: "plus") { zoom.zoomIn() }
                    .labelStyle(.iconOnly)
                    .disabled(!zoom.keyboard.canZoomIn)
                    .accessibilityIdentifier("zoomIn")
            }
            .buttonStyle(.bordered)

            HStack {
                Button("Pan Left", systemImage: "chevron.left") { zoom.panLeft() }
                    .labelStyle(.iconOnly)
                    .disabled(!zoom.keyboard.canPanLeft)
                    .accessibilityIdentifier("panLeft")

                Button("Fit Song") { zoom.fitSong() }
                    .tint(zoom.isFittedToSong ? PracticePalette.rightHand : .secondary)
                    .accessibilityIdentifier("zoomFitSong")

                Button("88 Keys") { zoom.showAllKeys() }
                    .tint(zoom.showsAllKeys ? PracticePalette.rightHand : .secondary)
                    .accessibilityIdentifier("zoom88Keys")

                Button("Pan Right", systemImage: "chevron.right") { zoom.panRight() }
                    .labelStyle(.iconOnly)
                    .disabled(!zoom.keyboard.canPanRight)
                    .accessibilityIdentifier("panRight")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var lookahead: some View {
        VStack(spacing: 6) {
            Text("\(zoom.lookaheadSeconds, format: .number.precision(.fractionLength(0...1)))s ahead")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .accessibilityIdentifier("zoomLookahead")

            Slider(value: $zoom.lookaheadSeconds, in: PracticeZoom.lookaheadRange, step: 0.5) {
                Text("Falling notes time window")
            } minimumValueLabel: {
                Text("2s")
            } maximumValueLabel: {
                Text("8s")
            }
            .accessibilityIdentifier("zoomLookaheadSlider")
        }
    }
}
