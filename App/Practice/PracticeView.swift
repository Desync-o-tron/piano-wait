import PianoWaitCore
import SwiftUI

struct PracticeView: View {
    @State private var session: PracticeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(song: MIDISong) {
        _session = State(initialValue: PracticeSession(song: song))
    }

    var body: some View {
        VStack(spacing: 0) {
            PracticeControlBar(session: session)
            if verticalSizeClass != .compact {
                PracticeStatusBar(session: session)
            }

            FallingNotesView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    // Landscape has little height to spare, so the status floats over the notes.
                    if verticalSizeClass == .compact {
                        PracticeStatusBar(session: session)
                    }
                }

            PianoKeyboardView(session: session)
                .containerRelativeFrame(.vertical) { height, _ in
                    min(height * 0.25, 180)
                }
        }
        .background(PracticePalette.background)
        .navigationTitle(session.song.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(verticalSizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task {
            await session.start()
        }
        .onDisappear {
            session.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .inactive else { return }
            session.handleScenePhase(isActive: newPhase == .active)
        }
    }
}
