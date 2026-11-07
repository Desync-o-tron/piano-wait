import Foundation

/// Stores MIDI files the player imported from elsewhere on the device.
public struct LocalSongStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        URL.documentsDirectory.appendingPathComponent("Imported", isDirectory: true)
    }

    /// Validates a MIDI file and copies it into the store, keeping any existing file of that name.
    @discardableResult
    public func importFile(at source: URL) throws -> URL {
        let data = try Data(contentsOf: source)
        _ = try MIDIParser.parse(data: data)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(forFileName: source.lastPathComponent)
        try data.write(to: destination, options: .withoutOverwriting)
        return destination
    }

    public func importedFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { CloudBucketClient.isMIDIFileName($0.lastPathComponent) }
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private func uniqueDestination(forFileName name: String) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }
}
