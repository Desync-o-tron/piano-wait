import Foundation
import XCTest
@testable import PianoWaitCore

final class CloudBucketClientTests: XCTestCase {
    private var cacheDirectory: URL!
    private var client: CloudBucketClient!

    override func setUpWithError() throws {
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudBucketClientTests-\(UUID().uuidString)", isDirectory: true)
        client = CloudBucketClient(bucket: "example-piano-midis", cacheDirectory: cacheDirectory, session: MockURLProtocol.makeSession())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private let listingJSON = Data("""
    {
      "kind": "storage#objects",
      "items": [
        {
          "kind": "storage#object",
          "name": "ode_to_joy.mid",
          "size": "1234",
          "updated": "2026-11-05T10:15:30.123Z",
          "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/example-piano-midis/o/ode_to_joy.mid?alt=media"
        },
        { "name": "Bach/Minuet in G.MIDI", "size": "99", "updated": "2026-11-05T10:15:30Z" },
        { "name": "cover.png", "size": "5000", "updated": "2026-11-05T10:15:30Z" },
        { "name": "folder/", "size": "0" },
        { "name": "notes.mid.txt", "size": "10" }
      ]
    }
    """.utf8)

    // MARK: - Listing

    func testParsesListing() throws {
        let (objects, nextPageToken) = try CloudBucketClient.parseListing(listingJSON)

        XCTAssertEqual(objects.map(\.name), ["ode_to_joy.mid", "Bach/Minuet in G.MIDI"])
        XCTAssertNil(nextPageToken)
        XCTAssertEqual(objects[0].size, 1234)
        XCTAssertEqual(objects[0].updated?.timeIntervalSince1970 ?? 0, 1_793_873_730.123, accuracy: 0.01)
        XCTAssertEqual(objects[1].updated?.timeIntervalSince1970 ?? 0, 1_793_873_730, accuracy: 0.01)
        XCTAssertEqual(objects[0].mediaLink?.host, "storage.googleapis.com")
        XCTAssertNil(objects[1].mediaLink)
    }

    func testParsesEmptyBucket() throws {
        let (objects, _) = try CloudBucketClient.parseListing(Data(#"{"kind":"storage#objects"}"#.utf8))
        XCTAssertTrue(objects.isEmpty)
    }

    func testMalformedListingThrows() {
        for body in ["not json", #"{"items":[{"size":"1"}]}"#, "[]"] {
            XCTAssertThrowsError(try CloudBucketClient.parseListing(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? CloudBucketError, .malformedListing)
            }
        }
    }

    func testListObjectsRequestsTheBucketAPI() async throws {
        let body = listingJSON
        MockURLProtocol.install { _ in (200, body) }

        let objects = try await client.listObjects()

        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(
            MockURLProtocol.requestedURLs.map(\.absoluteString),
            ["https://storage.googleapis.com/storage/v1/b/example-piano-midis/o"]
        )
    }

    func testListObjectsFollowsPagination() async throws {
        MockURLProtocol.install { request in
            if request.url?.query?.contains("pageToken=page2") == true {
                return (200, Data(#"{"items":[{"name":"b.mid","size":"2"}]}"#.utf8))
            }
            return (200, Data(#"{"items":[{"name":"a.mid","size":"1"}],"nextPageToken":"page2"}"#.utf8))
        }

        let objects = try await client.listObjects()

        XCTAssertEqual(objects.map(\.name), ["a.mid", "b.mid"])
        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 2)
    }

    func testListObjectsSurfacesHTTPErrors() async {
        MockURLProtocol.install { _ in (403, Data("denied".utf8)) }

        do {
            _ = try await client.listObjects()
            XCTFail("Expected an error.")
        } catch {
            XCTAssertEqual(error as? CloudBucketError, .httpStatus(403))
        }
    }

    func testListObjectsSurfacesNetworkErrors() async {
        MockURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await client.listObjects()
            XCTFail("Expected an error.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // MARK: - Download URLs

    func testDownloadURLEncodesTheName() {
        XCTAssertEqual(
            client.downloadURL(forObjectNamed: "ode_to_joy.mid").absoluteString,
            "https://storage.googleapis.com/example-piano-midis/ode_to_joy.mid"
        )
        XCTAssertEqual(
            client.downloadURL(forObjectNamed: "Bach/Minuet in G #1 (é)?.mid").absoluteString,
            "https://storage.googleapis.com/example-piano-midis/Bach/Minuet%20in%20G%20%231%20%28%C3%A9%29%3F.mid"
        )
    }

    // MARK: - Downloads and cache

    private func object(
        _ name: String = "song.mid",
        size: Int64 = 4,
        updated: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> BucketObject {
        BucketObject(name: name, size: size, updated: updated, mediaLink: nil)
    }

    func testDownloadWritesToTheCache() async throws {
        MockURLProtocol.install { _ in (200, Data([1, 2, 3, 4])) }

        let url = try await client.download(object())

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, cacheDirectory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3, 4]))
        XCTAssertEqual(client.cachedObjectNames(), ["song.mid"])
        XCTAssertTrue(client.isCached(object()))
    }

    func testDownloadRequestsTheDocumentedURL() async throws {
        MockURLProtocol.install { _ in (200, Data([1, 2, 3, 4])) }
        try await client.download(object("a b.mid"))
        XCTAssertEqual(
            MockURLProtocol.requestedURLs.first?.absoluteString,
            "https://storage.googleapis.com/example-piano-midis/a%20b.mid"
        )
    }

    func testFailedDownloadLeavesNothingCached() async {
        MockURLProtocol.install { _ in (404, Data("<Error/>".utf8)) }

        do {
            try await client.download(object())
            XCTFail("Expected an error.")
        } catch {
            XCTAssertEqual(error as? CloudBucketError, .httpStatus(404))
        }
        XCTAssertTrue(client.cachedObjectNames().isEmpty)
        XCTAssertFalse(client.isCached(object()))
    }

    func testTruncatedDownloadIsRejected() async {
        MockURLProtocol.install { _ in (200, Data([1, 2])) }

        do {
            try await client.download(object(size: 4))
            XCTFail("Expected an error.")
        } catch {
            XCTAssertEqual(error as? CloudBucketError, .incompleteDownload(expected: 4, received: 2))
        }
        XCTAssertTrue(client.cachedObjectNames().isEmpty)
    }

    func testChangedObjectIsNoLongerCurrent() async throws {
        MockURLProtocol.install { _ in (200, Data([1, 2, 3, 4])) }
        let original = object()
        try await client.download(original)
        XCTAssertTrue(client.isCached(original))

        XCTAssertFalse(client.isCached(object(updated: Date(timeIntervalSince1970: 1_800_000_000))), "newer")
        XCTAssertFalse(client.isCached(object(size: 5)), "different size")
        XCTAssertFalse(client.isCached(object("other.mid")), "different name")
    }

    func testNamesCannotEscapeTheCacheDirectory() throws {
        let directory = cacheDirectory.standardizedFileURL.path
        for name in ["../../evil.mid", "a/../../evil.mid", "/etc/evil.mid", "..%2Fevil.mid"] {
            let url = try client.cacheURL(forObjectNamed: name).standardizedFileURL
            XCTAssertEqual(url.deletingLastPathComponent().path, directory, name)
        }
    }

    func testNonMIDINamesAreRejected() {
        XCTAssertThrowsError(try client.cacheURL(forObjectNamed: "../../etc/passwd")) {
            XCTAssertEqual($0 as? CloudBucketError, .invalidObjectName("../../etc/passwd"))
        }
    }

    func testNestedAndSpecialNamesRoundTripThroughTheCache() async throws {
        MockURLProtocol.install { _ in (200, Data([1, 2, 3, 4])) }
        let names = ["Bach/Minuet in G.mid", "100% é.midi"]

        for name in names {
            try await client.download(object(name))
        }

        XCTAssertEqual(client.cachedObjectNames(), names.sorted())
        for name in names {
            XCTAssertTrue(client.isCached(object(name)), name)
        }
    }

    func testSyncDownloadsOnlyWhatIsMissingAndContinuesPastFailures() async throws {
        MockURLProtocol.install { request in
            request.url?.lastPathComponent == "bad.mid" ? (500, Data()) : (200, Data([1, 2, 3, 4]))
        }
        try await client.download(object("have.mid"))
        let before = MockURLProtocol.requestedURLs.count

        let result = await client.sync([object("have.mid"), object("bad.mid"), object("new.mid")])

        XCTAssertEqual(result.downloaded, ["new.mid"])
        XCTAssertEqual(result.failed, ["bad.mid"])
        XCTAssertEqual(MockURLProtocol.requestedURLs.count - before, 2)
    }

    func testRemoveAndClearCache() async throws {
        MockURLProtocol.install { _ in (200, Data([1, 2, 3, 4])) }
        try await client.download(object("a.mid"))
        try await client.download(object("b.mid"))

        try client.removeCachedObject(named: "a.mid")
        XCTAssertEqual(client.cachedObjectNames(), ["b.mid"])

        try client.clearCache()
        XCTAssertTrue(client.cachedObjectNames().isEmpty)
        XCTAssertNoThrow(try client.clearCache(), "Clearing an absent cache is harmless.")
    }

    func testCachedFilesSurviveANewClient() async throws {
        MockURLProtocol.install { _ in (200, Data([1, 2, 3, 4])) }
        try await client.download(object())

        let relaunched = CloudBucketClient(bucket: "example-piano-midis", cacheDirectory: cacheDirectory, session: MockURLProtocol.makeSession())

        XCTAssertEqual(relaunched.cachedObjectNames(), ["song.mid"])
        XCTAssertTrue(relaunched.isCached(object()))
    }

    // MARK: - Library merging

    func testLibraryMergesEverySource() throws {
        let remote = [object("zebra.mid"), object("stale.mid"), object("apple_pie.mid")]
        let songs = SongLibrary.merge(
            builtIns: BuiltInSongs.all,
            remote: remote,
            cachedNames: ["zebra.mid", "offline_only.mid"],
            isCurrent: { $0.name == "zebra.mid" },
            imported: [URL(fileURLWithPath: "/tmp/mine.mid")]
        )

        XCTAssertEqual(songs.filter { $0.availability == .builtIn }.count, 4)
        XCTAssertEqual(songs.first?.title, "Dark Is the Night")
        XCTAssertEqual(songs.first { $0.title == "Zebra" }?.availability, .cached)
        XCTAssertEqual(songs.first { $0.title == "Stale" }?.availability, .inCloud)
        XCTAssertEqual(songs.first { $0.title == "Apple Pie" }?.availability, .inCloud)
        XCTAssertEqual(songs.first { $0.title == "Offline Only" }?.availability, .cached)
        XCTAssertEqual(songs.first { $0.title == "Mine" }?.availability, .imported)
        XCTAssertEqual(Set(songs.map(\.id)).count, songs.count, "IDs must be unique.")
    }

    func testDisplayTitles() {
        XCTAssertEqual(SongLibrary.displayTitle(forFileName: "folder/ode_to_joy-v2.mid"), "Ode To Joy V2")
        XCTAssertEqual(SongLibrary.displayTitle(forFileName: "Minuet.MIDI"), "Minuet")
    }

    // MARK: - Imports

    func testImportValidatesAndAvoidsOverwriting() throws {
        let store = LocalSongStore(directory: cacheDirectory.appendingPathComponent("Imported"))
        let source = cacheDirectory.appendingPathComponent("incoming/tune.mid")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BuiltInSongs.odeToJoy.midiData.write(to: source)

        let first = try store.importFile(at: source)
        let second = try store.importFile(at: source)

        XCTAssertEqual(first.lastPathComponent, "tune.mid")
        XCTAssertEqual(second.lastPathComponent, "tune 2.mid")
        XCTAssertEqual(store.importedFiles().count, 2)

        try store.remove(first)
        XCTAssertEqual(store.importedFiles().count, 1)
    }

    func testImportRejectsFilesThatAreNotMIDI() throws {
        let store = LocalSongStore(directory: cacheDirectory.appendingPathComponent("Imported"))
        let source = cacheDirectory.appendingPathComponent("fake.mid")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("not midi".utf8).write(to: source)

        XCTAssertThrowsError(try store.importFile(at: source)) {
            XCTAssertEqual($0 as? MIDIParseError, .notMIDIFile)
        }
        XCTAssertTrue(store.importedFiles().isEmpty)
    }

    // MARK: - Keyboard layout

    func testKeyboardLayoutCoversThePiano() {
        let layout = PianoKeyboardLayout()
        XCTAssertEqual(layout.whiteKeyCount, 52)
        XCTAssertEqual(layout.frame(for: 21)?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(layout.frame(for: 20))
        XCTAssertNil(layout.frame(for: 109))
    }

    func testKeyboardHitTestingRoundTrips() {
        let layout = PianoKeyboardLayout()
        for note in MIDINote.pianoRange {
            let frame = layout.frame(for: note)!
            let hit = layout.note(atX: frame.x + frame.width / 2, y: MIDINote.isBlackKey(note) ? 0.3 : 0.9)
            XCTAssertEqual(hit, note, MIDINote.name(note))
        }
    }

    func testKeyboardAutoZoomFitsTheSong() throws {
        let song = try BuiltInSongs.odeToJoy.parsed()
        let layout = PianoKeyboardLayout.autoZoomed(for: song)

        XCTAssertLessThan(layout.whiteKeyCount, 52)
        for note in song.notes {
            XCTAssertNotNil(layout.frame(for: note.pitch))
        }
        XCTAssertFalse(MIDINote.isBlackKey(layout.range.lowerBound))
        XCTAssertFalse(MIDINote.isBlackKey(layout.range.upperBound))
    }

    func testNoteNames() {
        XCTAssertEqual(MIDINote.name(60), "C4")
        XCTAssertEqual(MIDINote.name(69), "A4")
        XCTAssertEqual(MIDINote.name(21), "A0")
        XCTAssertEqual(MIDINote.parse("C4"), 60)
        XCTAssertEqual(MIDINote.parse("F#5"), 78)
        XCTAssertEqual(MIDINote.parse("Bb3"), 58)
        XCTAssertNil(MIDINote.parse("H2"))
        XCTAssertNil(MIDINote.parse("C"))
        XCTAssertEqual(MIDINote.frequency(69), 440, accuracy: 1e-9)
    }
}

/// Talks to the real bucket, read-only.
final class CloudBucketLiveTests: XCTestCase {
    private func skipIfOffline(_ error: Error) throws {
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .timedOut, .dnsLookupFailed,
        ]
        if let urlError = error as? URLError, offlineCodes.contains(urlError.code) {
            throw XCTSkip("The bucket is unreachable from here: \(urlError.code)")
        }
    }

    func testLiveListingAndDownload() async throws {
        try XCTSkipUnless(!CloudBucketClient.defaultBucket.isEmpty, "Set PIANOWAIT_BUCKET to run live cloud bucket tests.")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudBucketLiveTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CloudBucketClient(cacheDirectory: directory)

        let objects: [BucketObject]
        do {
            objects = try await client.listObjects()
        } catch {
            try skipIfOffline(error)
            throw error
        }

        for object in objects {
            XCTAssertTrue(CloudBucketClient.isMIDIFileName(object.name), object.name)
            XCTAssertGreaterThan(object.size, 0, object.name)
            XCTAssertNotNil(object.updated, object.name)
        }

        guard let first = objects.first else { return }
        let url: URL
        do {
            url = try await client.download(first)
        } catch {
            try skipIfOffline(error)
            throw error
        }
        XCTAssertEqual(Int64(try Data(contentsOf: url).count), first.size)
        XCTAssertTrue(client.isCached(first))
    }
}
