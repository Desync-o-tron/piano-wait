import PianoWaitCore
import SwiftUI

/// Post-song completion card shown only when `session.state == .finished`.
/// Never shown while `session.state` is `.playing`, `.waiting`, or `.paused`.
struct PostSongSummaryCard: View {
    let session: PracticeSession
    let onPlayAgain: () -> Void
    let onBackToLibrary: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(PracticePalette.rightHand)

                Text("Song Complete!")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                Text(session.song.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                summaryMetric(
                    label: "Steps",
                    value: "\(session.stats.stepsCompleted)"
                )
                summaryMetric(
                    label: "Best Streak",
                    value: "\(session.stats.bestStreak)"
                )
                summaryMetric(
                    label: "Accuracy",
                    value: "\(Int((session.stats.accuracy * 100).rounded()))%"
                )
            }
            .padding(.vertical, 6)

            HStack(spacing: 12) {
                Button(action: onPlayAgain) {
                    Label("Play Again", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(PracticePalette.rightHand)
                .accessibilityIdentifier("summaryPlayAgain")

                Button(action: onBackToLibrary) {
                    Label("Library", systemImage: "music.note.list")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityIdentifier("summaryBackToLibrary")
            }

            AdBannerView(placement: .postSongSummary)
                .clipShape(.rect(cornerRadius: 10))
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PracticePalette.canvasTop.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
        )
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("postSongSummaryCard")
    }

    private func summaryMetric(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
