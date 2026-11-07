import Foundation

/// Writes Standard MIDI Files. Used for the built-in songs, the sample files, and test fixtures.
public struct MIDIFileBuilder: Sendable {
    public struct Track: Sendable {
        fileprivate var events: [TrackEvent] = []

        public init(name: String? = nil) {
            if let name {
                addMeta(type: 0x03, payload: Array(name.utf8), tick: 0)
            }
        }

        public mutating func addTempo(beatsPerMinute: Double, tick: Int = 0) {
            let microseconds = Int((60_000_000 / beatsPerMinute).rounded())
            addMeta(
                type: 0x51,
                payload: [UInt8(microseconds >> 16 & 0xFF), UInt8(microseconds >> 8 & 0xFF), UInt8(microseconds & 0xFF)],
                tick: tick
            )
        }

        public mutating func addTimeSignature(numerator: Int, denominator: Int, tick: Int = 0) {
            let power = denominator.trailingZeroBitCount
            addMeta(type: 0x58, payload: [UInt8(numerator), UInt8(power), 24, 8], tick: tick)
        }

        public mutating func addNote(
            pitch: UInt8,
            startTick: Int,
            durationTicks: Int,
            velocity: UInt8 = 80,
            channel: UInt8 = 0
        ) {
            events.append(TrackEvent(tick: startTick, order: 1, bytes: [0x90 | channel, pitch, velocity]))
            events.append(TrackEvent(tick: startTick + durationTicks, order: 0, bytes: [0x80 | channel, pitch, 0]))
        }

        private mutating func addMeta(type: UInt8, payload: [UInt8], tick: Int) {
            let bytes = [0xFF, type] + MIDIFileBuilder.variableLengthQuantity(payload.count) + payload
            events.append(TrackEvent(tick: tick, order: -1, bytes: bytes))
        }

        fileprivate func encoded() -> [UInt8] {
            var body: [UInt8] = []
            var previousTick = 0
            // Metadata comes first and note-offs precede note-ons on the same tick.
            let ordered = events.enumerated().sorted {
                ($0.element.tick, $0.element.order, $0.offset) < ($1.element.tick, $1.element.order, $1.offset)
            }
            for (_, event) in ordered {
                body += MIDIFileBuilder.variableLengthQuantity(event.tick - previousTick)
                body += event.bytes
                previousTick = event.tick
            }
            body += [0x00, 0xFF, 0x2F, 0x00]
            return Array("MTrk".utf8) + MIDIFileBuilder.bigEndian(UInt32(body.count)) + body
        }
    }

    public var ticksPerQuarter: Int
    public var tracks: [Track]

    public init(ticksPerQuarter: Int = 480, tracks: [Track] = []) {
        self.ticksPerQuarter = ticksPerQuarter
        self.tracks = tracks
    }

    public func build() -> Data {
        var bytes = Array("MThd".utf8)
        bytes += MIDIFileBuilder.bigEndian(UInt32(6))
        bytes += MIDIFileBuilder.bigEndian(UInt16(tracks.count > 1 ? 1 : 0))
        bytes += MIDIFileBuilder.bigEndian(UInt16(tracks.count))
        bytes += MIDIFileBuilder.bigEndian(UInt16(ticksPerQuarter))
        for track in tracks {
            bytes += track.encoded()
        }
        return Data(bytes)
    }

    public static func variableLengthQuantity(_ value: Int) -> [UInt8] {
        var remaining = value >> 7
        var encoded = [UInt8(value & 0x7F)]
        while remaining > 0 {
            encoded.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return encoded
    }

    private static func bigEndian<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}

private struct TrackEvent: Sendable {
    let tick: Int
    let order: Int
    let bytes: [UInt8]
}
