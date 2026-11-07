import Foundation
import PianoWaitCore

struct SongSummary: Equatable {
    let durationSeconds: TimeInterval
    let noteCount: Int

    init(song: MIDISong) {
        durationSeconds = song.durationSeconds
        noteCount = song.noteCount
    }
}
