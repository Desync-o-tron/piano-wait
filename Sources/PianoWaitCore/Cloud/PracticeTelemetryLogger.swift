import Foundation

/// Records compact microphone & wait-mode diagnostic events locally in `Documents/Telemetry/`
/// (and optionally uploads them if a custom telemetry bucket is explicitly configured).
public actor PracticeTelemetryLogger {
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
            topPeaks: [SpectralPeak]
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
    public let bucket: String
    private let startedAt: String
    private let session: URLSession
    private var diagnostics: [StepDiagnostic] = []
    private var lastUploadCount = 0

    public init(
        songTitle: String,
        bucket: String = CloudBucketClient.defaultBucket,
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
        self.bucket = bucket
        self.session = session
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

    @discardableResult
    public func uploadSnapshot(
        handSelection: String,
        noiseGateRMS: Float,
        latestTuningOffsetCents: Double,
        stats: PracticeStats,
        force: Bool = false
    ) async -> Bool {
        guard force || diagnostics.count >= lastUploadCount + 5 else { return false }
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

        // Only upload to a cloud bucket if one is explicitly configured and telemetry uploads are enabled.
        let cleanBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploadsEnabled = ProcessInfo.processInfo.environment["PIANOWAIT_UPLOAD_TELEMETRY"] == "1"
        guard !cleanBucket.isEmpty, uploadsEnabled else { return true }

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
}
