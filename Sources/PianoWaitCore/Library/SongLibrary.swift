import Foundation

public enum SongSource: Sendable, Hashable {
    case builtIn(BuiltInSong)
    case cloud(objectName: String)
    case imported(URL)
}

public enum SongAvailability: String, Sendable, Hashable {
    case builtIn = "Built-in"
    case cached = "Cached"
    case inCloud = "In Cloud"
    case imported = "Imported"
}

public struct LibrarySong: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let source: SongSource
    public let availability: SongAvailability
    /// The listed object, when the bucket has been reached in this session.
    public let object: BucketObject?

    public var isBuiltIn: Bool { availability == .builtIn }
}

public enum SongLibrary {
    /// Combines every song source. Files that are cached but missing from the listing stay in the
    /// library, which is what keeps it usable offline.
    public static func merge(
        builtIns: [BuiltInSong],
        remote: [BucketObject],
        cachedNames: [String],
        isCurrent: (BucketObject) -> Bool,
        imported: [URL]
    ) -> [LibrarySong] {
        var songs = builtIns.map {
            LibrarySong(id: "builtin:\($0.id)", title: $0.title, source: .builtIn($0), availability: .builtIn, object: nil)
        }

        let remoteNames = Set(remote.map(\.name))
        var cloudSongs = remote.map { object in
            LibrarySong(
                id: "cloud:\(object.name)",
                title: displayTitle(forFileName: object.name),
                source: .cloud(objectName: object.name),
                availability: isCurrent(object) ? .cached : .inCloud,
                object: object
            )
        }
        for name in cachedNames where !remoteNames.contains(name) {
            cloudSongs.append(LibrarySong(
                id: "cloud:\(name)",
                title: displayTitle(forFileName: name),
                source: .cloud(objectName: name),
                availability: .cached,
                object: nil
            ))
        }
        songs += cloudSongs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        songs += imported.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            LibrarySong(
                id: "imported:\(url.lastPathComponent)",
                title: displayTitle(forFileName: url.lastPathComponent),
                source: .imported(url),
                availability: .imported,
                object: nil
            )
        }
        return songs
    }

    /// Turns `folder/ode_to_joy-v2.mid` into `Ode To Joy V2`.
    public static func displayTitle(forFileName name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let words = stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let title = words.trimmingCharacters(in: .whitespaces).capitalized
        return title.isEmpty ? base : title
    }
}
