import Foundation
import Observation
import PianoWaitCore
import UIKit

/// Connects the practice engine to the microphone, synthesizer, and clock, and publishes a
/// snapshot of its state for the views.
@MainActor
@Observable
final class PracticeSession {
    enum MicrophoneStatus: Equatable {
        case off
        case listening
        case denied
        case unavailable(String)
    }

    /// Seconds before the first note, giving the falling notes room to fall.
    private static let leadIn: TimeInterval = 2
    private static let tickInterval = Duration.milliseconds(16)

    let song: MIDISong

    var zoom: PracticeZoom
    private(set) var playhead: TimeInterval
    private(set) var state = PlaybackState.paused
    private(set) var waitingNotes = Set<UInt8>()
    private(set) var latchedNotes = Set<UInt8>()
    private(set) var heardNotes = Set<UInt8>()
    private(set) var pressedKeys = Set<UInt8>()
    private(set) var stats = PracticeStats()
    private(set) var progress = 0.0
    private(set) var stepStatuses: [StepStatus]
    private(set) var microphoneLevel: Float = 0
    private(set) var microphoneStatus = MicrophoneStatus.off
    private(set) var tuningOffsetCents: Double = 0
    private(set) var loopStart: TimeInterval?
    private(set) var loopEnd: TimeInterval?

    var isWaitMode = true {
        didSet { engine.setMode(isWaitMode ? .waitForMe : .continuous) }
    }
    var speed = 1.0 {
        didSet { engine.setSpeed(speed) }
    }
    var handSelection = HandSelection.both {
        didSet { engine.setHandSelection(handSelection) }
    }
    var autoPlayAccompaniment = false {
        didSet { engine.autoPlayAccompaniment = autoPlayAccompaniment }
    }
    var playsReferenceAudio = false {
        didSet { engine.playsReferenceAudio = playsReferenceAudio }
    }
    /// The microphone noise gate as RMS level. Higher values ignore more of the room.
    var noiseGate: Float = 0.0012 {
        didSet { microphone.setNoiseGate(noiseGate) }
    }
    /// Whether the user has opted into sharing anonymized mic & note telemetry to improve pitch detection.
    var isSharingMicTelemetry: Bool = PracticeTelemetryLogger.isUserOptedIn {
        didSet { PracticeTelemetryLogger.isUserOptedIn = isSharingMicTelemetry }
    }

    private let engine: WaitModeEngine
    private let synth = PianoSynth()
    private let microphone = MicrophoneInput()
    private let telemetry: PracticeTelemetryLogger
    private var clockTask: Task<Void, Never>?
    private var isStarted = false
    private var trackedStepIndex: Int?
    private var trackedStepEnteredAt = Date()
    private var trackedStepHeard = Set<UInt8>()
    private var trackedStepRaw = Set<UInt8>()
    private var trackedStepLatched = Set<UInt8>()
    private var trackedStepPeakRMS: Float = 0
    private var trackedStepTopPeaks: [SpectralPeak] = []
    private var trackedStepPeakCandidates: [EvaluatedCandidateRecord] = []
    private var trackedStepAttemptFrames: [PracticeTelemetryLogger.AttemptFrameSnapshot] = []
    private var lastAttemptCaptureTime = Date.distantPast
    private var autoPanKeyboardToExpectedNotes = true
    private var showUpcomingStepHighlight = true

    init(song: MIDISong) {
        self.song = song
        zoom = PracticeZoom(song: song)
        telemetry = PracticeTelemetryLogger(songTitle: song.title)
        var configuration = WaitModeEngine.Configuration()
        configuration.leadIn = Self.leadIn
        configuration.rollWindow = 0.85
        configuration.earlyGrace = 0.45
        configuration.strikeMemorySeconds = 0.85
        configuration.partialChordGraceSeconds = 0.9
        engine = WaitModeEngine(song: song, configuration: configuration)
        playhead = -Self.leadIn
        stepStatuses = engine.stepStatuses
        microphone.setNoiseGate(noiseGate)
        microphone.setOnsetSensitivity(riseRatio: 1.18, fallRatio: 0.92)
    }

    var isPlaying: Bool {
        state == .playing || state == .waiting
    }

    var songProgressFraction: Double {
        guard song.durationSeconds > 0 else { return 0 }
        return min(max(playhead / song.durationSeconds, 0), 1)
    }

    var songProgressText: String {
        let elapsed = Duration.seconds(max(0, playhead)).formatted(.time(pattern: .minuteSecond))
        let total = Duration.seconds(song.durationSeconds).formatted(.time(pattern: .minuteSecond))
        return "\(elapsed) / \(total)"
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        UIApplication.shared.isIdleTimerDisabled = true
        startClock()

        Task { @MainActor [weak self] in
            let ota = await RemoteConfigLoader.shared.refresh()
            self?.applyOTAConfiguration(ota)
        }

        guard !AppEnvironment.isUITesting || AppEnvironment.usesMicrophoneInUITest else { return }
        await startAudio()
    }

    private func applyOTAConfiguration(_ ota: OTAConfiguration) {
        if let engineConfig = ota.engine {
            engineConfig.apply(to: &engine.configuration)
        }
        if let dspConfig = ota.dsp {
            if let gate = dspConfig.noiseGateRMS {
                noiseGate = gate
            }
            microphone.applyOTADSP(dspConfig)
        }
        if let uiConfig = ota.ui {
            if let autoPan = uiConfig.autoPanKeyboardToExpectedNotes {
                autoPanKeyboardToExpectedNotes = autoPan
            }
            if let showUpcoming = uiConfig.showUpcomingStepHighlight {
                showUpcomingStepHighlight = showUpcoming
            }
        }
        if let telemetryConfig = ota.telemetry {
            Task {
                await telemetry.applyOTATelemetry(telemetryConfig)
            }
        }
        publish()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        UIApplication.shared.isIdleTimerDisabled = false
        clockTask?.cancel()
        clockTask = nil
        flushTelemetry(force: true)
        microphone.stop()
        synth.allNotesOff()
        synth.stop()
        AudioSessionConfigurator.deactivate()
    }

    /// Playback stops in the background, and iOS may have stopped the audio engines by the time
    /// the app returns, so they restart when it becomes active.
    func handleScenePhase(isActive: Bool) {
        guard isStarted else { return }
        if isActive {
            guard microphoneStatus == .listening else { return }
            do {
                try AudioSessionConfigurator.activateForPractice()
                try synth.start()
                try microphone.resumeIfNeeded()
            } catch {
                microphoneStatus = .unavailable(error.localizedDescription)
            }
        } else if isPlaying {
            togglePlayback()
        }
    }

    private func startAudio() async {
        let isGranted = await AudioSessionConfigurator.requestMicrophonePermission()
        // The view may have gone away while the permission prompt was up.
        guard isStarted else { return }

        do {
            try AudioSessionConfigurator.activateForPractice()
            try synth.start()
        } catch {
            microphoneStatus = .unavailable(error.localizedDescription)
            return
        }

        guard isGranted else {
            microphoneStatus = .denied
            return
        }

        do {
            try microphone.start { [weak self] frame in
                Task { @MainActor in
                    self?.handle(frame)
                }
            }
            microphoneStatus = .listening
        } catch {
            microphoneStatus = .unavailable(error.localizedDescription)
        }
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await clock.sleep(for: Self.tickInterval)
                let now = clock.now
                let elapsed = last.duration(to: now)
                last = now
                self?.tick(deltaTime: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
            }
        }
    }

    // MARK: - Engine

    private func tick(deltaTime: TimeInterval) {
        perform(engine.tick(deltaTime: deltaTime))
        publish()
    }

    private func handle(_ frame: PitchDetectionFrameResult) {
        guard isStarted else { return }
        microphoneLevel = frame.rms
        tuningOffsetCents = frame.tuningOffsetCents
        heardNotes = frame.activeNotes.union(frame.matchedExpectedNotes)
        if state == .waiting {
            trackedStepHeard.formUnion(frame.soundingNotes)
            trackedStepRaw.formUnion(frame.rawNotes)
            if frame.rms > trackedStepPeakRMS {
                trackedStepPeakRMS = frame.rms
                if !frame.topPeaks.isEmpty {
                    trackedStepTopPeaks = frame.topPeaks
                }
                if !frame.evaluatedCandidates.isEmpty {
                    trackedStepPeakCandidates = frame.evaluatedCandidates
                }
            }
            let now = Date()
            if (!frame.onsets.isEmpty || (frame.rms >= noiseGate * 3 && !frame.evaluatedCandidates.isEmpty)),
               trackedStepAttemptFrames.count < 16,
               now.timeIntervalSince(lastAttemptCaptureTime) >= 0.12 {
                lastAttemptCaptureTime = now
                let elapsed = max(0, now.timeIntervalSince(trackedStepEnteredAt))
                trackedStepAttemptFrames.append(
                    PracticeTelemetryLogger.AttemptFrameSnapshot(
                        offsetSeconds: elapsed,
                        rms: frame.rms,
                        soundingNotes: frame.soundingNotes.sorted().map(MIDINote.name),
                        rawNotes: frame.rawNotes.sorted().map(MIDINote.name),
                        onsets: frame.onsets.sorted().map(MIDINote.name),
                        topPeaks: frame.topPeaks,
                        evaluatedCandidates: frame.evaluatedCandidates
                    )
                )
            }
        }
        engine.ingest(frame)
        perform(engine.drainEvents())
        publish()
    }

    private func perform(_ events: [PracticeEvent]) {
        for event in events {
            switch event {
            case .playNote(let pitch, let velocity, let duration):
                synth.noteOn(note: pitch, velocity: velocity, duration: duration)
            case .stepCompleted:
                break
            case .finished:
                flushTelemetry(force: true)
            case .looped:
                flushTelemetry(force: false)
            }
        }
    }

    private func publish() {
        playhead = engine.playhead
        state = engine.state
        waitingNotes = showUpcomingStepHighlight ? engine.upcomingNotes : engine.waitingNotes
        latchedNotes = engine.latched
        stats = engine.stats
        progress = engine.progress
        stepStatuses = engine.stepStatuses
        microphone.setExpectedNotes(engine.notesForDetector)
        if autoPanKeyboardToExpectedNotes, !waitingNotes.isEmpty {
            let shifted = zoom.keyboard.ensuringVisible(waitingNotes)
            if shifted != zoom.keyboard {
                zoom.keyboard = shifted
            }
        }
        if state == .waiting, let step = engine.currentStepIndex, trackedStepIndex != step {
            if let prev = trackedStepIndex, prev < engine.stepStatuses.count, engine.stepStatuses[prev] == .completed {
                recordStepDiagnostic(stepIndex: prev, outcome: "completed", latched: trackedStepLatched)
            }
            trackedStepIndex = step
            trackedStepEnteredAt = Date()
            trackedStepHeard.removeAll()
            trackedStepRaw.removeAll()
            trackedStepLatched.removeAll()
            trackedStepPeakRMS = 0
            trackedStepTopPeaks = []
            trackedStepPeakCandidates = []
            trackedStepAttemptFrames = []
            microphone.clearRecentAudio()
        } else if state != .waiting, let prev = trackedStepIndex {
            if prev < engine.stepStatuses.count, engine.stepStatuses[prev] == .completed {
                recordStepDiagnostic(stepIndex: prev, outcome: "completed", latched: trackedStepLatched)
            }
            trackedStepIndex = nil
        }
        if state == .waiting {
            trackedStepLatched.formUnion(engine.latched)
        }
    }

    private func recordStepDiagnostic(stepIndex: Int, outcome: String, latched overrideLatched: Set<UInt8>? = nil) {
        guard stepIndex < song.steps.count else { return }
        let step = song.steps[stepIndex]
        let expected = step.pitches(for: handSelection)
        let latched = overrideLatched ?? engine.latched.union(trackedStepLatched)
        let missing = expected.subtracting(latched)
        let waited = max(0, Date().timeIntervalSince(trackedStepEnteredAt))
        let shouldCaptureAudio = isSharingMicTelemetry
            && (outcome == "skipped" || waited >= 1.5 || expected.count >= 2 || stepIndex % 8 == 0)
        let audioSnapshot: (samples: [Float], sampleRate: Double) = shouldCaptureAudio
            ? microphone.snapshotRecentAudio(maxSeconds: min(max(waited + 0.5, 1.5), 3.5))
            : (samples: [], sampleRate: 0)
        let stepSongTime = step.timeSeconds
        let expectedNames = expected.sorted().map(MIDINote.name)
        let latchedNames = latched.sorted().map(MIDINote.name)
        let missingNames = missing.sorted().map(MIDINote.name)
        let heardNames = trackedStepHeard.sorted().map(MIDINote.name)
        let rawNames = trackedStepRaw.sorted().map(MIDINote.name)
        let peakRMS = trackedStepPeakRMS
        let tuning = tuningOffsetCents
        let topPeaks = trackedStepTopPeaks
        let peakCandidates = trackedStepPeakCandidates
        let attemptFrames = trackedStepAttemptFrames
        let hands = "\(handSelection)"
        let gate = noiseGate
        let currentStats = stats
        Task {
            var snippetObject: String? = nil
            if !audioSnapshot.samples.isEmpty {
                snippetObject = await telemetry.uploadAudioSnippet(
                    samples: audioSnapshot.samples,
                    sampleRate: audioSnapshot.sampleRate,
                    stepIndex: stepIndex,
                    outcome: outcome
                )
            }
            let diag = PracticeTelemetryLogger.StepDiagnostic(
                stepIndex: stepIndex,
                songTimeSeconds: stepSongTime,
                waitedSeconds: waited,
                outcome: outcome,
                expectedNotes: expectedNames,
                latchedNotes: latchedNames,
                missingNotes: missingNames,
                heardNotesDuringStep: heardNames,
                rawNotesDuringStep: rawNames,
                peakRMS: peakRMS,
                tuningOffsetCents: tuning,
                topPeaks: topPeaks,
                peakEvaluatedCandidates: peakCandidates,
                attemptFrames: attemptFrames,
                audioSnippetObjectName: snippetObject
            )
            await telemetry.record(diag)
            await telemetry.uploadSnapshot(
                handSelection: hands,
                noiseGateRMS: gate,
                latestTuningOffsetCents: tuning,
                stats: currentStats,
                force: outcome == "skipped" || waited >= 2.0
            )
        }
    }

    private func flushTelemetry(force: Bool) {
        let hands = "\(handSelection)"
        let gate = noiseGate
        let tuning = tuningOffsetCents
        let currentStats = stats
        Task {
            await telemetry.uploadSnapshot(
                handSelection: hands,
                noiseGateRMS: gate,
                latestTuningOffsetCents: tuning,
                stats: currentStats,
                force: force
            )
        }
    }

    // MARK: - Controls

    func togglePlayback() {
        switch engine.state {
        case .playing, .waiting:
            engine.pause()
            synth.allNotesOff()
        case .paused:
            engine.play()
        case .finished:
            engine.restart()
            engine.play()
        }
        publish()
    }

    func restart() {
        engine.restart()
        synth.allNotesOff()
        publish()
    }

    func skipStep() {
        if let step = engine.currentStepIndex {
            recordStepDiagnostic(stepIndex: step, outcome: "skipped")
        }
        engine.skipStep()
        perform(engine.drainEvents())
        publish()
    }

    func markLoopStart() {
        loopStart = max(0, playhead)
        loopEnd = nil
        engine.clearLoop()
    }

    func markLoopEnd() {
        guard let loopStart else { return }
        let end = max(0, playhead)
        if engine.setLoop(start: loopStart, end: end) {
            loopEnd = end
        }
        publish()
    }

    func clearLoop() {
        loopStart = nil
        loopEnd = nil
        engine.clearLoop()
    }

    func seek(to fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        let targetSeconds = clamped * song.durationSeconds
        synth.allNotesOff()
        trackedStepIndex = nil
        engine.seek(to: targetSeconds)
        perform(engine.drainEvents())
        publish()
    }

    func keyPressed(_ note: UInt8) {
        pressedKeys.insert(note)
        synth.noteOn(note: note)
        engine.registerKeyPress(note)
        perform(engine.drainEvents())
        publish()
    }

    func keyReleased(_ note: UInt8) {
        pressedKeys.remove(note)
        synth.noteOff(note: note)
    }
}
