import Foundation
import PianoWaitCore

/// A parsed song on its way to the practice screen.
struct PracticeSong: Identifiable, Hashable {
    let id: String
    let song: MIDISong

    static func == (lhs: PracticeSong, rhs: PracticeSong) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
