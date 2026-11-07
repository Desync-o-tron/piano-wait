import Foundation

/// A MIDI file listed in the cloud bucket.
public struct BucketObject: Sendable, Hashable, Identifiable {
    public let name: String
    public let size: Int64
    public let updated: Date?
    public let mediaLink: URL?

    public var id: String { name }

    public init(name: String, size: Int64, updated: Date?, mediaLink: URL?) {
        self.name = name
        self.size = size
        self.updated = updated
        self.mediaLink = mediaLink
    }
}
