import SwiftUI

struct SyncStatusRow: View {
    let state: LibraryModel.SyncState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .syncing:
            Label {
                Text("Syncing with the bucket…")
            } icon: {
                ProgressView()
            }
            .foregroundStyle(.secondary)
        case .synced(let date):
            Label("Synced \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("Offline: downloaded songs still work. \(message)", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}
