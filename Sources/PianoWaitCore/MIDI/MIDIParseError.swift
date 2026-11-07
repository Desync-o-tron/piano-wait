import Foundation

public enum MIDIParseError: Error, Equatable, LocalizedError {
    case emptyData
    case notMIDIFile
    case invalidHeader
    case unsupportedFormat(Int)
    case noTracks
    case truncatedData
    case invalidVariableLengthQuantity
    case missingRunningStatus
    case invalidStatusByte(UInt8)
    case noPlayableNotes

    public var errorDescription: String? {
        switch self {
        case .emptyData: "The file is empty."
        case .notMIDIFile: "This is not a Standard MIDI File."
        case .invalidHeader: "The MIDI header is invalid."
        case .unsupportedFormat(let format): "MIDI format \(format) is not supported."
        case .noTracks: "The MIDI file has no tracks."
        case .truncatedData: "The MIDI file is truncated."
        case .invalidVariableLengthQuantity: "The MIDI file has an invalid variable-length value."
        case .missingRunningStatus: "The MIDI file has data with no status byte."
        case .invalidStatusByte(let byte): "The MIDI file has an invalid status byte (\(byte))."
        case .noPlayableNotes: "The MIDI file has no notes a piano can play."
        }
    }
}
