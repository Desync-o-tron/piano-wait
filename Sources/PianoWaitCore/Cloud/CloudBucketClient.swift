import Foundation

public enum CloudBucketError: Error, Equatable, LocalizedError {
    case httpStatus(Int)
    case malformedListing
    case invalidObjectName(String)
    case incompleteDownload(expected: Int64, received: Int64)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status): "The bucket responded with HTTP status \(status)."
        case .malformedListing: "The bucket listing could not be read."
        case .invalidObjectName(let name): "\"\(name)\" is not a MIDI file name."
        case .incompleteDownload(let expected, let received):
            "The download was incomplete (\(received) of \(expected) bytes)."
        }
    }
}

/// Lists a public Google Cloud Storage bucket and caches its MIDI files for offline use.
public struct CloudBucketClient: Sendable {
    public static let defaultBucket: String = {
        if let env = ProcessInfo.processInfo.environment["PIANOWAIT_BUCKET"], !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "PianoWaitBucket") as? String, !plist.isEmpty {
            return plist
        }
        return ""
    }()

    public var isConfigured: Bool {
        !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public struct SyncResult: Sendable, Equatable {
        public var downloaded: [String] = []
        public var failed: [String] = []
    }

    public let bucket: String
    public let cacheDirectory: URL

    private let session: URLSession

    public init(
        bucket: String = CloudBucketClient.defaultBucket,
        cacheDirectory: URL,
        session: URLSession = .shared
    ) {
        self.bucket = bucket
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    /// The conventional cache location, `Documents/MIDIs`.
    public static func defaultCacheDirectory() -> URL {
        URL.documentsDirectory.appendingPathComponent("MIDIs", isDirectory: true)
    }

    // MARK: - Remote

    public var listingURL: URL {
        URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o")!
    }

    public func downloadURL(forObjectNamed name: String) -> URL {
        URL(string: "https://storage.googleapis.com/\(bucket)/\(Self.encodePath(name))")!
    }

    /// Lists every MIDI object in the bucket, following pagination.
    public func listObjects() async throws -> [BucketObject] {
        guard isConfigured else { return [] }
        var objects: [BucketObject] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: listingURL, resolvingAgainstBaseURL: false)!
            if let pageToken {
                components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
            }
            let data = try await fetch(components.url!)
            let page = try Self.parseListing(data)
            objects += page.objects
            pageToken = page.nextPageToken
        } while pageToken != nil
        return objects
    }

    /// Parses one page of a JSON API listing, keeping only `.mid` and `.midi` objects.
    public static func parseListing(_ data: Data) throws -> (objects: [BucketObject], nextPageToken: String?) {
        let listing: ListingResponse
        do {
            listing = try JSONDecoder().decode(ListingResponse.self, from: data)
        } catch {
            throw CloudBucketError.malformedListing
        }

        let objects = (listing.items ?? []).compactMap { item -> BucketObject? in
            guard isMIDIFileName(item.name) else { return nil }
            return BucketObject(
                name: item.name,
                size: Int64(item.size ?? "") ?? 0,
                updated: item.updated.flatMap(parseDate),
                mediaLink: item.mediaLink.flatMap(URL.init(string:))
            )
        }
        return (objects, listing.nextPageToken)
    }

    /// Downloads an object into the cache and returns its local file.
    @discardableResult
    public func download(_ object: BucketObject) async throws -> URL {
        let destination = try cacheURL(forObjectNamed: object.name)
        let data = try await fetch(downloadURL(forObjectNamed: object.name))
        if object.size > 0, Int64(data.count) != object.size {
            throw CloudBucketError.incompleteDownload(expected: object.size, received: Int64(data.count))
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        if let updated = object.updated {
            // The cached file carries the object's timestamp, which is how staleness is detected.
            try FileManager.default.setAttributes([.modificationDate: updated], ofItemAtPath: destination.path)
        }
        return destination
    }

    /// Downloads every object that is missing or out of date. One failure does not stop the rest.
    public func sync(_ objects: [BucketObject]) async -> SyncResult {
        var result = SyncResult()
        for object in objects where !isCached(object) {
            do {
                try await download(object)
                result.downloaded.append(object.name)
            } catch {
                result.failed.append(object.name)
            }
        }
        return result
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CloudBucketError.httpStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Local cache

    /// Object names come from the network, so they are percent-encoded into one flat file name.
    /// That leaves no path separators through which a name could escape the cache directory.
    public func cacheURL(forObjectNamed name: String) throws -> URL {
        guard Self.isMIDIFileName(name) else { throw CloudBucketError.invalidObjectName(name) }
        return cacheDirectory.appendingPathComponent(Self.encodeFileName(name), isDirectory: false)
    }

    /// Whether an up-to-date copy of the object is cached.
    public func isCached(_ object: BucketObject) -> Bool {
        guard let url = try? cacheURL(forObjectNamed: object.name),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64
        else { return false }

        if object.size > 0, size != object.size { return false }
        if let updated = object.updated, let modified = attributes[.modificationDate] as? Date {
            return modified.timeIntervalSince(updated) > -1
        }
        return true
    }

    /// The names of all cached objects, so that the library works offline.
    public func cachedObjectNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        return files.compactMap { $0.removingPercentEncoding }.filter(Self.isMIDIFileName).sorted()
    }

    public func removeCachedObject(named name: String) throws {
        try FileManager.default.removeItem(at: try cacheURL(forObjectNamed: name))
    }

    public func clearCache() throws {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        try FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Helpers

    public static func isMIDIFileName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".mid") || lowered.hasSuffix(".midi")
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Encodes everything but unreserved characters and the `/` that separates path segments.
    private static func encodePath(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: unreservedCharacters.union(CharacterSet(charactersIn: "/"))) ?? name
    }

    private static func encodeFileName(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? name
    }

    private static func parseDate(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }
}

private struct ListingResponse: Decodable {
    struct Item: Decodable {
        let name: String
        let size: String?
        let updated: String?
        let mediaLink: String?
    }

    let items: [Item]?
    let nextPageToken: String?
}
