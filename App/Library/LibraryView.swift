import PianoWaitCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var isImporting = false
    @State private var activeSong: PracticeSong?
    @State private var openingSongID: LibrarySong.ID?

    var body: some View {
        @Bindable var library = library

        NavigationStack {
            List {
                SyncStatusRow(state: library.syncState)

                section("Built-in", songs: library.builtInSongs)
                if library.isCloudConfigured || !library.cloudSongs.isEmpty {
                    section(
                        library.isCloudConfigured ? "gs://\(library.cloudBucketName)" : "Cloud Songs",
                        songs: library.cloudSongs
                    )
                }
                if !library.importedSongs.isEmpty {
                    section("Imported", songs: library.importedSongs)
                }
            }
            .navigationTitle("PianoWait")
            .refreshable {
                await library.syncBucket()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Import", systemImage: "square.and.arrow.down") {
                        isImporting = true
                    }
                }
                if library.isCloudConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Sync Bucket", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await library.syncBucket() }
                        }
                        .disabled(library.syncState == .syncing)
                        .accessibilityIdentifier("syncBucket")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.midi],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    for url in urls { library.importFile(at: url) }
                case .failure(let error):
                    library.errorMessage = error.localizedDescription
                }
            }
            .navigationDestination(item: $activeSong) { practiceSong in
                PracticeView(song: practiceSong.song)
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { library.errorMessage != nil },
                    set: { if !$0 { library.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? "")
            }
            .task {
                await library.refreshListing()
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, songs: [LibrarySong]) -> some View {
        Section(title) {
            if songs.isEmpty {
                ContentUnavailableView(
                    "No Cloud Songs Yet",
                    systemImage: "icloud.slash",
                    description: Text("Pull down to sync, or upload MIDI files to the bucket.")
                )
            }
            ForEach(songs) { song in
                Button {
                    open(song)
                } label: {
                    SongRow(
                        song: song,
                        summary: library.summaries[song.id],
                        isBusy: openingSongID == song.id || library.downloadingSongIDs.contains(song.id)
                    )
                }
                .buttonStyle(.plain)
                .disabled(openingSongID != nil)
                .accessibilityIdentifier("song-\(song.title)")
                .swipeActions {
                    if library.canDelete(song) {
                        Button(song.availability == .imported ? "Delete" : "Remove Download", role: .destructive) {
                            library.delete(song)
                        }
                    }
                }
            }
        }
    }

    private func open(_ song: LibrarySong) {
        openingSongID = song.id
        Task {
            defer { openingSongID = nil }
            activeSong = await library.openSong(song)
        }
    }
}
