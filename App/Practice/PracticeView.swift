import PianoWaitCore
import SwiftUI

struct PracticeView: View {
    @State private var session: PracticeSession
    @State private var isShowingTelemetryPrompt = false
    @Environment(\.dismiss) private var dismiss
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
                .overlay {
                    if AdPlacementPolicy.allowsAdInPracticeView(for: session.state) {
                        PostSongSummaryCard(
                            session: session,
                            onPlayAgain: {
                                session.restart()
                                session.togglePlayback()
                            },
                            onBackToLibrary: {
                                dismiss()
                            }
                        )
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
            AdManager.shared.updatePlaybackState(session.state)
            await session.start()
        }
        .onDisappear {
            AdManager.shared.updatePlaybackState(.paused)
            session.stop()
        }
        .onChange(of: session.state) { _, newState in
            AdManager.shared.updatePlaybackState(newState)
            if newState == .finished {
                AdManager.shared.handleSongFinished(in: newState)
            }
        }
        .onChange(of: session.microphoneStatus) { _, status in
            if status == .listening, !AppEnvironment.isUITesting, !PracticeTelemetryLogger.hasPromptedUser {
                isShowingTelemetryPrompt = true
            }
        }
        .alert("Help Improve Mic Detection?", isPresented: $isShowingTelemetryPrompt) {
            Button("Share & Help Improve") {
                session.isSharingMicTelemetry = true
            }
            Button("Not Now", role: .cancel) {
                PracticeTelemetryLogger.hasPromptedUser = true
            }
        } message: {
            Text("Would you like to share short anonymized piano audio snippets and note accuracy data while practicing so we can make a better microphone pitch algorithm?")
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .inactive else { return }
            session.handleScenePhase(isActive: newPhase == .active)
        }
    }
}
