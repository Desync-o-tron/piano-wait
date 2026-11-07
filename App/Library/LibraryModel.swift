import Foundation
import Observation
import PianoWaitCore

/// The song library: built-in songs, the cloud bucket, and imports.
@MainActor
@Observable
final class LibraryModel {
    enum SyncState: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    private(set) var songs: [LibrarySong] = []
    private(set) var summaries: [LibrarySong.ID: SongSummary] = [:]
    private(set) var syncState = SyncState.idle
    private(set) var downloadingSongIDs = Set<LibrarySong.ID>()
    var errorMessage: String?

    private let client = CloudBucketClient(cacheDirectory: CloudBucketClient.defaultCacheDirectory())
    private let store = LocalSongStore(directory: LocalSongStore.defaultDirectory())
    private var remoteObjects: [BucketObject] = []

    init() {
        rebuild()
    }

    var builtInSongs: [LibrarySong] { songs.filter { $0.availability == .builtIn } }
    var cloudSongs: [LibrarySong] { songs.filter { $0.availability == .cached || $0.availability == .inCloud } }
    var importedSongs: [LibrarySong] { songs.filter { $0.availability == .imported } }

    // MARK: - Sync

    var isCloudConfigured: Bool { client.isConfigured }
    var cloudBucketName: String { client.bucket }

    /// Fetches the listing without downloading anything, so the library is current on launch.
    func refreshListing() async {
        guard !AppEnvironment.isUITesting, client.isConfigured else { return }
        await updateListing()
    }

    /// Fetches the listing and downloads everything that is missing or out of date.
    func syncBucket() async {
        guard client.isConfigured else { return }
        guard await updateListing() else { return }

        let result = await client.sync(remoteObjects)
        rebuild()
        if !result.failed.isEmpty {
            syncState = .failed("Could not download \(result.failed.joined(separator: ", ")).")
        }
    }

    @discardableResult
    private func updateListing() async -> Bool {
        syncState = .syncing
        do {
            remoteObjects = try await client.listObjects()
            rebuild()
            syncState = .synced(.now)
            return true
        } catch {
            syncState = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: - Opening songs

    /// Parses a song for practice, downloading it first if needed. Returns nil after reporting a
    /// failure through `errorMessage`.
    func openSong(_ song: LibrarySong) async -> PracticeSong? {
        do {
            let data = try await loadData(for: song)
            let parsed = try MIDIParser.parse(data: data, title: song.title)
            summaries[song.id] = SongSummary(song: parsed)
            return PracticeSong(id: song.id, song: parsed)
        } catch {
            errorMessage = "Could not open \(song.title). \(error.localizedDescription)"
            return nil
        }
    }

    private func loadData(for song: LibrarySong) async throws -> Data {
        switch song.source {
        case .builtIn(let builtIn):
            return builtIn.midiData
        case .imported(let url):
            return try Data(contentsOf: url)
        case .cloud(let name):
            if song.availability == .inCloud, let object = song.object {
                downloadingSongIDs.insert(song.id)
                defer { downloadingSongIDs.remove(song.id) }
                try await client.download(object)
                rebuild()
            }
            return try Data(contentsOf: client.cacheURL(forObjectNamed: name))
        }
    }

    // MARK: - Imports and removal

    func importFile(at url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            try store.importFile(at: url)
            rebuild()
        } catch {
            errorMessage = "Could not import \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    func delete(_ song: LibrarySong) {
        do {
            switch song.source {
            case .builtIn:
                return
            case .imported(let url):
                try store.remove(url)
            case .cloud(let name):
                try client.removeCachedObject(named: name)
            }
            summaries[song.id] = nil
            rebuild()
        } catch {
            errorMessage = "Could not remove \(song.title). \(error.localizedDescription)"
        }
    }

    func canDelete(_ song: LibrarySong) -> Bool {
        song.availability == .imported || song.availability == .cached
    }

    // MARK: - Building the list

    private func rebuild() {
        songs = SongLibrary.merge(
            builtIns: BuiltInSongs.all,
            remote: remoteObjects,
            cachedNames: client.cachedObjectNames(),
            isCurrent: client.isCached,
            imported: store.importedFiles()
        )
        for song in songs where summaries[song.id] == nil {
            summaries[song.id] = summary(for: song)
        }
    }

    /// Duration and note count come from the file, so cloud songs only have them once cached.
    private func summary(for song: LibrarySong) -> SongSummary? {
        let data: Data?
        switch song.source {
        case .builtIn(let builtIn):
            data = builtIn.midiData
        case .imported(let url):
            data = try? Data(contentsOf: url)
        case .cloud(let name):
            guard song.availability == .cached else { return nil }
            data = (try? client.cacheURL(forObjectNamed: name)).flatMap { try? Data(contentsOf: $0) }
        }
        return data.flatMap { try? MIDIParser.parse(data: $0) }.map(SongSummary.init)
    }
}
