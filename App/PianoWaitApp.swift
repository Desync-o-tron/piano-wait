import SwiftUI

@main
struct PianoWaitApp: App {
    @State private var library = LibraryModel()
    @State private var adManager = AdManager.shared

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(adManager)
                .tint(PracticePalette.rightHand)
                .task {
                    adManager.startIfNeeded()
                }
        }
    }
}
