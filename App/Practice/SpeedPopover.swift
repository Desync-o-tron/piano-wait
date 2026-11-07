import PianoWaitCore
import SwiftUI

struct SpeedPopover: View {
    @Binding var speed: Double

    var body: some View {
        VStack(spacing: 14) {
            Text("\(Int((speed * 100).rounded()))%")
                .font(.title2.monospacedDigit().weight(.semibold))

            Slider(value: $speed, in: WaitModeEngine.speedRange, step: 0.05) {
                Text("Speed")
            } minimumValueLabel: {
                Text("0.25x")
            } maximumValueLabel: {
                Text("2x")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 6) {
                ForEach(WaitModeEngine.speedPresets, id: \.self) { preset in
                    Button("\(Int(preset * 100))%") {
                        speed = preset
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(speed == preset ? PracticePalette.rightHand : .secondary)
                }
            }
        }
        .padding()
        .frame(minWidth: 340)
    }
}
