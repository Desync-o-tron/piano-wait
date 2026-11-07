import Foundation
import PianoWaitCore

// Writes the sample MIDI files: `swift run pianowait-samples [output-directory]`.
let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "samples", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for sample in BuiltInSongs.sampleFiles {
    let url = directory.appendingPathComponent(sample.fileName)
    try sample.midiData.write(to: url, options: .atomic)
    let song = try sample.parsed()
    print("\(url.path): \(song.noteCount) notes, \(song.steps.count) steps, \(String(format: "%.1f", song.durationSeconds))s")
}
