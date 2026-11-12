import Foundation

/// Records compact microphone & wait-mode diagnostic events locally in `Documents/Telemetry/`
/// and, when the user opts in (`PracticeTelemetryLogger.isUserOptedIn`), uploads anonymized
/// step diagnostics and short WAV audio snippets to `gs://luke-piano-telemetry` to help train
/// and improve the acoustic piano pitch detector.
public actor PracticeTelemetryLogger {
    public static let defaultTelemetryBucket = "luke-piano-telemetry"
    public static let optInDefaultsKey = "pianowait.shareMicTelemetryOptIn"
    public static let optInPromptShownKey = "pianowait.shareMicTelemetryPromptShown"

    public nonisolated static var isUserOptedIn: Bool {
        get {
            if ProcessInfo.processInfo.environment["PIANOWAIT_UPLOAD_TELEMETRY"] == "1" {
                return true
            }
            return UserDefaults.standard.bool(forKey: optInDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: optInDefaultsKey)
            UserDefaults.standard.set(true, forKey: optInPromptShownKey)
        }
    }

    public nonisolated static var hasPromptedUser: Bool {
        get { UserDefaults.standard.bool(forKey: optInPromptShownKey) }
        set { UserDefaults.standard.set(newValue, forKey: optInPromptShownKey) }
    }

    public struct AttemptFrameSnapshot: Codable, Sendable, Equatable {
        public let offsetSeconds: Double
        public let rms: Float
        public let soundingNotes: [String]
        public let rawNotes: [String]
        public let onsets: [String]
        public let topPeaks: [SpectralPeak]
        public let evaluatedCandidates: [EvaluatedCandidateRecord]

        public init(
            offsetSeconds: Double,
            rms: Float,
            soundingNotes: [String],
            rawNotes: [String],
            onsets: [String],
            topPeaks: [SpectralPeak],
            evaluatedCandidates: [EvaluatedCandidateRecord] = []
        ) {
            self.offsetSeconds = offsetSeconds
            self.rms = rms
            self.soundingNotes = soundingNotes
            self.rawNotes = rawNotes
            self.onsets = onsets
            self.topPeaks = topPeaks
            self.evaluatedCandidates = evaluatedCandidates
        }
    }

    public struct StepDiagnostic: Codable, Sendable, Equatable {
        public let stepIndex: Int
        public let songTimeSeconds: Double
        public let waitedSeconds: Double
        public let outcome: String
        public let expectedNotes: [String]
        public let latchedNotes: [String]
        public let missingNotes: [String]
        public let heardNotesDuringStep: [String]
        public let rawNotesDuringStep: [String]
        public let peakRMS: Float
        public let tuningOffsetCents: Double
        public let topPeaks: [SpectralPeak]
        public let peakEvaluatedCandidates: [EvaluatedCandidateRecord]
        public let attemptFrames: [AttemptFrameSnapshot]
        public let audioSnippetObjectName: String?

        public init(
            stepIndex: Int,
            songTimeSeconds: Double,
            waitedSeconds: Double,
            outcome: String,
            expectedNotes: [String],
            latchedNotes: [String],
            missingNotes: [String],
            heardNotesDuringStep: [String],
            rawNotesDuringStep: [String],
            peakRMS: Float,
            tuningOffsetCents: Double,
            topPeaks: [SpectralPeak],
            peakEvaluatedCandidates: [EvaluatedCandidateRecord] = [],
            attemptFrames: [AttemptFrameSnapshot] = [],
            audioSnippetObjectName: String? = nil
        ) {
            self.stepIndex = stepIndex
            self.songTimeSeconds = songTimeSeconds
            self.waitedSeconds = waitedSeconds
            self.outcome = outcome
            self.expectedNotes = expectedNotes
            self.latchedNotes = latchedNotes
            self.missingNotes = missingNotes
            self.heardNotesDuringStep = heardNotesDuringStep
            self.rawNotesDuringStep = rawNotesDuringStep
            self.peakRMS = peakRMS
            self.tuningOffsetCents = tuningOffsetCents
            self.topPeaks = topPeaks
            self.peakEvaluatedCandidates = peakEvaluatedCandidates
            self.attemptFrames = attemptFrames
            self.audioSnippetObjectName = audioSnippetObjectName
        }
    }

    public struct SessionReport: Codable, Sendable, Equatable {
        public let sessionId: String
        public let songTitle: String
        public let startedAtISO8601: String
        public let updatedAtISO8601: String
        public let handSelection: String
        public let noiseGateRMS: Float
        public let latestTuningOffsetCents: Double
        public let stepsCompleted: Int
        public let stepsSkipped: Int
        public let wrongNotes: Int
        public let diagnostics: [StepDiagnostic]
    }

    public let sessionId: String
    public let songTitle: String
    public var bucket: String
    public var isOTAEnabled = true
    public var isAudioUploadEnabled = true
    public var flushStepInterval = 5
    private let startedAt: String
    private let session: URLSession
    private var diagnostics: [StepDiagnostic] = []
    private var lastUploadCount = 0
    private var uploadedAudioSnippetsCount = 0

    public init(
        songTitle: String,
        bucket: String = PracticeTelemetryLogger.defaultTelemetryBucket,
        session: URLSession = .shared
    ) {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        self.startedAt = formatter.string(from: now)
        let compactTimestamp = Int(now.timeIntervalSince1970)
        let safeSong = songTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        self.sessionId = "\(compactTimestamp)_\(safeSong)_\(UUID().uuidString.prefix(6))"
        self.songTitle = songTitle
        let resolvedBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bucket = resolvedBucket.isEmpty ? Self.defaultTelemetryBucket : resolvedBucket
        self.session = session
    }

    public func applyOTATelemetry(_ config: OTAConfiguration.Telemetry?) {
        guard let config else { return }
        if let enabled = config.enabled {
            isOTAEnabled = enabled
        }
        if let interval = config.flushStepInterval, interval >= 1 {
            flushStepInterval = interval
        }
        if let audio = config.uploadAudioSnippets {
            isAudioUploadEnabled = audio
        }
        if let customBucket = config.telemetryBucket?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customBucket.isEmpty {
            bucket = customBucket
        }
    }

    public func record(_ diagnostic: StepDiagnostic) {
        diagnostics.append(diagnostic)
        if diagnostics.count > 250 {
            diagnostics.removeFirst(diagnostics.count - 250)
        }
    }

    public func diagnosticCount() -> Int {
        diagnostics.count
    }

    public func snippetObjectName(forStep stepIndex: Int, outcome: String) -> String {
        "audio/\(sessionId)_step\(stepIndex)_\(outcome).wav"
    }

    @discardableResult
    public func uploadAudioSnippet(
        samples: [Float],
        sampleRate: Double,
        stepIndex: Int,
        outcome: String
    ) async -> String? {
        guard Self.isUserOptedIn, isOTAEnabled, isAudioUploadEnabled else { return nil }
        guard uploadedAudioSnippetsCount < 25 else { return nil }
        let cleanBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBucket.isEmpty, !samples.isEmpty, sampleRate > 0 else { return nil }

        let wavData = Self.encodeMonoWAV16kHz(samples: samples, sourceSampleRate: sampleRate)
        guard !wavData.isEmpty else { return nil }

        let objectName = snippetObjectName(forStep: stepIndex, outcome: outcome)
        let localDir = URL.documentsDirectory.appendingPathComponent("Telemetry/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localFile = localDir.appendingPathComponent("\(sessionId)_step\(stepIndex)_\(outcome).wav")
        try? wavData.write(to: localFile, options: .atomic)

        guard let encodedName = objectName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://storage.googleapis.com/upload/storage/v1/b/\(cleanBucket)/o?uploadType=media&name=\(encodedName)")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                uploadedAudioSnippetsCount += 1
                return objectName
            }
            return nil
        } catch {
            return nil
        }
    }

    @discardableResult
    public func uploadSnapshot(
        handSelection: String,
        noiseGateRMS: Float,
        latestTuningOffsetCents: Double,
        stats: PracticeStats,
        force: Bool = false
    ) async -> Bool {
        guard force || diagnostics.count >= lastUploadCount + flushStepInterval else { return false }
        guard !diagnostics.isEmpty || force else { return false }
        lastUploadCount = diagnostics.count

        let report = SessionReport(
            sessionId: sessionId,
            songTitle: songTitle,
            startedAtISO8601: startedAt,
            updatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            handSelection: handSelection,
            noiseGateRMS: noiseGateRMS,
            latestTuningOffsetCents: latestTuningOffsetCents,
            stepsCompleted: stats.stepsCompleted,
            stepsSkipped: stats.stepsSkipped,
            wrongNotes: stats.wrongNotes,
            diagnostics: diagnostics
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let payload = try? encoder.encode(report) else { return false }

        // Save locally so diagnostics are available on device.
        let localDir = URL.documentsDirectory.appendingPathComponent("Telemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localFile = localDir.appendingPathComponent("\(sessionId).json")
        try? payload.write(to: localFile, options: .atomic)

        // Upload to the write-only telemetry bucket when the user has opted in.
        let cleanBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBucket.isEmpty, Self.isUserOptedIn, isOTAEnabled else { return true }

        let objectName = "telemetry/\(sessionId)_\(diagnostics.count).json"
        guard let encodedName = objectName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://storage.googleapis.com/upload/storage/v1/b/\(cleanBucket)/o?uploadType=media&name=\(encodedName)")
        else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    /// Downsamples float PCM audio to 16 kHz 16-bit mono WAV so a 3.5-second piano snippet is ~112 KB.
    public nonisolated static func encodeMonoWAV16kHz(samples: [Float], sourceSampleRate: Double) -> Data {
        guard !samples.isEmpty, sourceSampleRate > 0 else { return Data() }
        let targetRate = 16_000
        let ratio = sourceSampleRate / Double(targetRate)
        let outCount = max(1, Int(Double(samples.count) / ratio))
        var pcm16 = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = min(samples.count - 1, Int(Double(i) * ratio))
            let clamped = max(-1.0 as Float, min(1.0 as Float, samples[srcIdx]))
            pcm16[i] = Int16(clamped * 32767.0)
        }

        let dataSize = UInt32(outCount * 2)
        let fileSize = 36 + dataSize
        var wav = Data(capacity: Int(44 + dataSize))

        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: littleEndianUInt32(fileSize))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: littleEndianUInt32(16)) // PCM chunk size
        wav.append(contentsOf: littleEndianUInt16(1))  // AudioFormat = 1 (PCM)
        wav.append(contentsOf: littleEndianUInt16(1))  // NumChannels = 1 (Mono)
        wav.append(contentsOf: littleEndianUInt32(UInt32(targetRate)))
        wav.append(contentsOf: littleEndianUInt32(UInt32(targetRate * 2))) // ByteRate
        wav.append(contentsOf: littleEndianUInt16(2))  // BlockAlign
        wav.append(contentsOf: littleEndianUInt16(16)) // BitsPerSample
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: littleEndianUInt32(dataSize))

        for sample in pcm16 {
            wav.append(contentsOf: littleEndianUInt16(UInt16(bitPattern: sample)))
        }
        return wav
    }

    private nonisolated static func littleEndianUInt16(_ value: UInt16) -> [UInt8] {
        let le = value.littleEndian
        return [UInt8(le & 0xFF), UInt8((le >> 8) & 0xFF)]
    }

    private nonisolated static func littleEndianUInt32(_ value: UInt32) -> [UInt8] {
        let le = value.littleEndian
        return [
            UInt8(le & 0xFF),
            UInt8((le >> 8) & 0xFF),
            UInt8((le >> 16) & 0xFF),
            UInt8((le >> 24) & 0xFF)
        ]
    }
}
