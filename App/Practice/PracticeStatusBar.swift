import PianoWaitCore
import SwiftUI

struct PracticeStatusBar: View {
    let session: PracticeSession
    @State private var isDraggingScrubber = false
    @State private var scrubFraction: Double?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 14) {
                statusBadge
                    .accessibilityIdentifier("practiceStatus")

                Spacer()

                stat("Streak", value: "\(session.stats.currentStreak)")
                stat("Steps", value: "\(session.stats.stepsCompleted)")
                    .accessibilityIdentifier("stepsCompleted")
                if abs(session.tuningOffsetCents) >= 1 {
                    stat(
                        "Tune",
                        value: "\(session.tuningOffsetCents >= 0 ? "+" : "")\(Int(session.tuningOffsetCents.rounded()))¢"
                    )
                }

                Text(displayTimeText)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 5)

            scrubberBar
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [
                    PracticePalette.background.opacity(0.95),
                    PracticePalette.background.opacity(0.75)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var activeFraction: Double {
        scrubFraction ?? session.songProgressFraction
    }

    private var displayTimeText: String {
        if let scrubFraction {
            let target = scrubFraction * session.song.durationSeconds
            let elapsed = Duration.seconds(max(0, target)).formatted(.time(pattern: .minuteSecond))
            let total = Duration.seconds(session.song.durationSeconds).formatted(.time(pattern: .minuteSecond))
            return "\(elapsed) / \(total)"
        }
        return session.songProgressText
    }

    private var scrubberBar: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let progressX = width * CGFloat(min(max(activeFraction, 0), 1))
            let trackHeight: CGFloat = isDraggingScrubber ? 7 : 5
            let thumbSize: CGFloat = isDraggingScrubber ? 16 : 11

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(height: trackHeight)

                if let loopStart = session.loopStart, session.song.durationSeconds > 0 {
                    let startFrac = min(max(loopStart / session.song.durationSeconds, 0), 1)
                    let endFrac = min(max((session.loopEnd ?? session.playhead) / session.song.durationSeconds, startFrac), 1)
                    Capsule()
                        .fill(PracticePalette.expected.opacity(0.35))
                        .frame(width: max(4, width * CGFloat(endFrac - startFrac)), height: trackHeight)
                        .offset(x: width * CGFloat(startFrac))
                }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [PracticePalette.leftHand, PracticePalette.rightHand],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackHeight, progressX), height: trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: PracticePalette.rightHand.opacity(0.7), radius: isDraggingScrubber ? 6 : 3)
                    .offset(x: min(max(0, progressX - thumbSize / 2), width - thumbSize))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDraggingScrubber = true
                        let fraction = min(max(Double(value.location.x / width), 0), 1)
                        scrubFraction = fraction
                        session.seek(to: fraction)
                    }
                    .onEnded { value in
                        let fraction = min(max(Double(value.location.x / width), 0), 1)
                        session.seek(to: fraction)
                        scrubFraction = nil
                        isDraggingScrubber = false
                    }
            )
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Song progress")
        .accessibilityValue("\(Int((activeFraction * 100).rounded())) percent")
        .accessibilityIdentifier("progressScrubber")
    }

    private var statusBadge: some View {
        Text(statusString)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.14), in: .capsule)
    }

    private var statusString: String {
        switch session.state {
        case .paused:
            return "Paused"
        case .playing:
            return session.isWaitMode ? "Get ready" : "Play along"
        case .waiting:
            let names = session.waitingNotes.subtracting(session.latchedNotes).sorted().map(MIDINote.name)
            return "Play \(names.joined(separator: " "))"
        case .finished:
            return "Finished!"
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .waiting: PracticePalette.expected
        case .finished: PracticePalette.rightHand
        default: .white
        }
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
