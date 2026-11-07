import Foundation

/// Launch options used by UI tests.
enum AppEnvironment {
    /// Keeps the audio session and microphone off, and the library off the network.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    /// With `--uitesting`, turns the microphone back on to exercise the real audio path.
    static var usesMicrophoneInUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-microphone")
    }
}
