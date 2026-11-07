import PianoWaitCore
import SwiftUI

struct SongRow: View {
    let song: LibrarySong
    let summary: SongSummary?
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconStyle)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.headline)
                Text(detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isBusy {
                ProgressView()
            } else {
                Text(song.availability.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(iconStyle.opacity(0.15), in: .capsule)
                    .foregroundStyle(iconStyle)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        if let summary {
            let duration = Duration.seconds(summary.durationSeconds)
                .formatted(.time(pattern: .minuteSecond))
            return "\(duration) · \(summary.noteCount) notes"
        }
        if let size = song.object?.size {
            return size.formatted(.byteCount(style: .file))
        }
        return "Tap to download"
    }

    private var iconName: String {
        switch song.availability {
        case .builtIn: "music.note"
        case .cached: "checkmark.icloud"
        case .inCloud: "icloud.and.arrow.down"
        case .imported: "doc.badge.arrow.up"
        }
    }

    private var iconStyle: Color {
        switch song.availability {
        case .builtIn: .purple
        case .cached: PracticePalette.rightHand
        case .inCloud: PracticePalette.leftHand
        case .imported: .orange
        }
    }
}
