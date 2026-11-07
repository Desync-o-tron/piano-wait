import SwiftUI

@main
struct PianoWaitApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .tint(PracticePalette.rightHand)
        }
    }
}
