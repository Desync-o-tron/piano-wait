import Foundation

enum TickTiming: Equatable {
    case ticksPerQuarter(Int)
    case smpte(ticksPerSecond: Double)

    init(division: UInt16) throws {
        if division & 0x8000 == 0 {
            guard division > 0 else { throw MIDIParseError.invalidHeader }
            self = .ticksPerQuarter(Int(division))
        } else {
            let framesPerSecond = -Int(Int8(truncatingIfNeeded: division >> 8))
            let ticksPerFrame = Int(division & 0xFF)
            guard framesPerSecond > 0, ticksPerFrame > 0 else { throw MIDIParseError.invalidHeader }
            // SMPTE code 29 means 29.97 drop-frame.
            let rate = framesPerSecond == 29 ? 29.97 : Double(framesPerSecond)
            self = .smpte(ticksPerSecond: rate * Double(ticksPerFrame))
        }
    }
}

struct TempoChange {
    let tick: Int
    let microsecondsPerQuarter: Int
}

/// Converts ticks to seconds, integrating across every tempo change in the file.
struct TempoMap {
    let events: [TempoEvent]
    private let timing: TickTiming

    init(changes: [TempoChange], timing: TickTiming, defaultMicrosecondsPerQuarter: Int) {
        self.timing = timing

        // A stable sort keeps file order, so the last tempo set on a shared tick wins.
        let ordered = changes.enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)

        var built = [TempoEvent(tick: 0, microsecondsPerQuarter: defaultMicrosecondsPerQuarter, seconds: 0)]
        for change in ordered {
            guard let last = built.last else { continue }
            if change.tick == last.tick {
                built[built.count - 1] = TempoEvent(
                    tick: last.tick,
                    microsecondsPerQuarter: change.microsecondsPerQuarter,
                    seconds: last.seconds
                )
            } else {
                let seconds = last.seconds + Self.duration(ticks: change.tick - last.tick, tempo: last, timing: timing)
                built.append(TempoEvent(
                    tick: change.tick,
                    microsecondsPerQuarter: change.microsecondsPerQuarter,
                    seconds: seconds
                ))
            }
        }
        events = built
    }

    func seconds(atTick tick: Int) -> TimeInterval {
        var low = 0
        var high = events.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if events[middle].tick <= tick {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let tempo = events[low]
        return tempo.seconds + Self.duration(ticks: tick - tempo.tick, tempo: tempo, timing: timing)
    }

    private static func duration(ticks: Int, tempo: TempoEvent, timing: TickTiming) -> TimeInterval {
        switch timing {
        case .ticksPerQuarter(let ticksPerQuarter):
            Double(ticks) * Double(tempo.microsecondsPerQuarter) / 1_000_000 / Double(ticksPerQuarter)
        case .smpte(let ticksPerSecond):
            Double(ticks) / ticksPerSecond
        }
    }
}
