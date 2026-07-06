import Foundation

// One JSON line emitted by MLRuntime/Analysis/score_runner.py.
private struct AnalysisRunnerEvent: Decodable {
    let type: String
    let stage: String?
    let message: String?
    let progress: Double?
    let output: String?
}

// Shape of the score JSON written by score_runner.py (--output).
private struct RunnerScore: Decodable {
    struct TriadNote: Decodable {
        let name: String
        let midi: Int
    }
    struct Beat: Decodable {
        let time: Double
        let position: Int
        let chord: String
        let triad: [TriadNote]
        let lyric: String
    }
    struct Measure: Decodable {
        let number: Int
        let time_signature: String
        let start: Double
        let end: Double
        let beats: [Beat]
        let lyric: String
    }

    let instrument: String
    let song_duration: Double
    let bpm: Double
    let beats_per_bar: Int
    let key: String?
    let language: String?
    let measures: [Measure]
}

enum AnalysisProcessError: LocalizedError {
    case runtimeNotInstalled(String)
    case runnerNotFound(String)
    case missingStems(String)
    case ffmpegNotFound
    case processFailed(status: Int32, message: String)
    case runnerError(String)
    case missingCompletedEvent
    case missingOutputFile(String)
    case unreadableOutput(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled(let path):
            return """
            Analysis runtime belum tersedia.

            Jalankan:
            ./Scripts/setup_analysis.sh

            Runtime yang dicari:
            \(path)
            """

        case .runnerNotFound(let path):
            return "score_runner.py tidak ditemukan di \(path)"

        case .missingStems(let dir):
            return """
            Stem hasil separation tidak lengkap.

            Dibutuhkan bass/drums/other/vocals.wav di:
            \(dir)
            """

        case .ffmpegNotFound:
            return """
            FFmpeg tidak ditemukan.

            Instal FFmpeg dengan:
            brew install ffmpeg
            """

        case .processFailed(let status, let message):
            return """
            Analysis berhenti dengan exit code \(status).

            \(message)
            """

        case .runnerError(let message):
            return message

        case .missingCompletedEvent:
            return "Analysis selesai tanpa memberikan hasil."

        case .missingOutputFile(let path):
            return "File score tidak ditemukan setelah analysis: \(path)"

        case .unreadableOutput(let path):
            return "File score tidak dapat dibaca: \(path)"
        }
    }
}

private enum AnalysisDevelopmentRuntime {
    static var repositoryRootURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // Services
        url.deleteLastPathComponent() // StemStudio source folder
        url.deleteLastPathComponent() // Repository root
        return url
    }

    static var pythonURL: URL {
        repositoryRootURL
            .appendingPathComponent(".local")
            .appendingPathComponent("analysis")
            .appendingPathComponent("venv")
            .appendingPathComponent("bin")
            .appendingPathComponent("python")
    }

    static var runnerURL: URL {
        repositoryRootURL
            .appendingPathComponent("MLRuntime")
            .appendingPathComponent("Analysis")
            .appendingPathComponent("score_runner.py")
    }

    static var modelsURL: URL {
        repositoryRootURL
            .appendingPathComponent(".local")
            .appendingPathComponent("analysis")
            .appendingPathComponent("models")
    }

    private static func executableExists(named executableName: String) -> Bool {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return directories.contains { directory in
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: directory)
                    .appendingPathComponent(executableName).path
            )
        }
    }

    static func validate() throws {
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw AnalysisProcessError.runtimeNotInstalled(pythonURL.path)
        }

        guard fileManager.fileExists(atPath: runnerURL.path) else {
            throw AnalysisProcessError.runnerNotFound(runnerURL.path)
        }

        // Whisper decodes audio through ffmpeg.
        guard executableExists(named: "ffmpeg") else {
            throw AnalysisProcessError.ffmpegNotFound
        }
    }
}

// Real vocal sheet-music generation. Runs the analysis runner on the four
// already-separated stems (separation is skipped inside the runner).
struct AnalysisProcessService: ScoreGenerationService {
    var whisperModel: String = "medium"
    var beatModel: String = "allin1-finetuned"

    func generateScore(
        from stem: StemAsset,
        audioURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws -> ScoreAsset {
        let fileManager = FileManager.default

        try AnalysisDevelopmentRuntime.validate()

        // All four stems live alongside the selected stem file.
        let stemsDirectory = audioURL.deletingLastPathComponent()
        for name in ["bass", "drums", "other", "vocals"] {
            let path = stemsDirectory.appendingPathComponent("\(name).wav").path
            guard fileManager.fileExists(atPath: path) else {
                throw AnalysisProcessError.missingStems(stemsDirectory.path)
            }
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("stemstudio-score-\(UUID().uuidString).json")

        progress(0.02, "Preparing analysis runtime")

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = AnalysisDevelopmentRuntime.pythonURL
        process.arguments = [
            AnalysisDevelopmentRuntime.runnerURL.path,
            "--stems-dir", stemsDirectory.path,
            "--output", outputURL.path,
            "--instrument", "vocals",
            "--device", "cpu",
            "--models-dir", AnalysisDevelopmentRuntime.modelsURL.path,
            "--whisper-model", whisperModel,
            "--beat-model", beatModel,
        ]
        process.currentDirectoryURL = AnalysisDevelopmentRuntime.repositoryRootURL
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"

        // torch / natten / madmom each pull in an OpenMP runtime. When the child
        // is spawned by a GUI app (rather than a shell), colliding/oversubscribed
        // OpenMP runtimes can abort the process mid-inference. Pin the thread
        // count and tolerate a duplicate libomp so native inference stays stable.
        environment["OMP_NUM_THREADS"] = "4"
        environment["MKL_NUM_THREADS"] = "4"
        environment["KMP_DUPLICATE_LIB_OK"] = "TRUE"
        environment["TOKENIZERS_PARALLELISM"] = "false"

        // When launched from Xcode/Finder the app's environment can carry
        // debugger-injected DYLD_* overrides and stray Python vars. Inherited by
        // the child, these make native libs (e.g. natten) load the wrong dylibs
        // and abort. Strip them so the venv resolves its own libraries cleanly.
        for key in [
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
            "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH",
            "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP",
        ] {
            environment.removeValue(forKey: key)
        }

        let requiredPaths = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = (requiredPaths + [currentPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")

        process.environment = environment

        async let terminationStatus = run(process)
        async let standardErrorText = readToEnd(errorPipe.fileHandleForReading)

        var didComplete = false
        var runnerErrorMessage: String?
        var diagnosticLines: [String] = []
        var lastProgress = 0.02

        let decoder = JSONDecoder()

        for try await line in outputPipe.fileHandleForReading.bytes.lines {
            guard !line.isEmpty else { continue }

            guard
                let data = line.data(using: .utf8),
                let event = try? decoder.decode(AnalysisRunnerEvent.self, from: data)
            else {
                diagnosticLines.append(line)
                continue
            }

            switch event.type {
            case "status":
                progress(lastProgress, event.message ?? "Analyzing")

            case "progress":
                if let value = event.progress {
                    lastProgress = min(max(value, 0), 1)
                }
                progress(lastProgress, event.message ?? "Analyzing")

            case "completed":
                didComplete = true
                progress(1.0, "Sheet music ready")

            case "error":
                runnerErrorMessage = event.message ?? "Analysis failed."

            case "cancelled":
                runnerErrorMessage = event.message ?? "Analysis was cancelled."

            default:
                break
            }
        }

        let status = try await terminationStatus
        let standardError = await standardErrorText

        // Always persist the child's stderr so native crashes (which bypass the
        // runner's JSON error path) remain diagnosable.
        let logURL = AnalysisDevelopmentRuntime.repositoryRootURL
            .appendingPathComponent(".local")
            .appendingPathComponent("analysis")
            .appendingPathComponent("last-run.stderr.log")
        try? standardError.write(to: logURL, atomically: true, encoding: .utf8)

        if let runnerErrorMessage {
            throw AnalysisProcessError.runnerError(runnerErrorMessage)
        }

        guard status == 0 else {
            let diagnostics = [standardError, diagnosticLines.joined(separator: "\n")]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw AnalysisProcessError.processFailed(
                status: status,
                message: diagnostics.isEmpty ? "No additional error information." : diagnostics
            )
        }

        guard didComplete else {
            throw AnalysisProcessError.missingCompletedEvent
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw AnalysisProcessError.missingOutputFile(outputURL.path)
        }

        guard let scoreData = try? Data(contentsOf: outputURL) else {
            throw AnalysisProcessError.unreadableOutput(outputURL.path)
        }

        let runnerScore = try decoder.decode(RunnerScore.self, from: scoreData)
        try? fileManager.removeItem(at: outputURL)

        return makeScoreAsset(from: runnerScore, stem: stem)
    }

    // MARK: - Mapping

    private func makeScoreAsset(from runner: RunnerScore, stem: StemAsset) -> ScoreAsset {
        // Flat ordered beat times, to give each note a real duration.
        let flatBeats = runner.measures.flatMap { $0.beats }
        let times = flatBeats.map { $0.time }

        func duration(after index: Int) -> Double {
            if index + 1 < times.count {
                return max(0.1, times[index + 1] - times[index])
            }
            return max(0.1, runner.song_duration - times[index])
        }

        var flatNotes: [NoteEvent] = []
        var noteCursor = 0

        let measures: [ScoreMeasure] = runner.measures.map { m in
            let beats: [ScoreBeat] = m.beats.map { b in
                let dur = duration(after: noteCursor)
                noteCursor += 1

                let triad = b.triad.map { note in
                    NoteEvent(
                        id: UUID(),
                        pitch: note.name,
                        midi: note.midi,
                        startTime: b.time,
                        duration: dur,
                        confidence: 1.0
                    )
                }

                // One representative note per beat for the Practice timeline.
                if let root = triad.first {
                    flatNotes.append(root)
                }

                return ScoreBeat(
                    id: UUID(),
                    time: b.time,
                    position: b.position,
                    chord: b.chord,
                    triad: triad,
                    lyric: b.lyric
                )
            }

            return ScoreMeasure(
                id: UUID(),
                number: m.number,
                timeSignature: m.time_signature,
                start: m.start,
                end: m.end,
                beats: beats,
                lyric: m.lyric
            )
        }

        return ScoreAsset(
            id: UUID(),
            stemID: stem.id,
            instrument: stem.type,
            createdAt: Date(),
            notes: flatNotes,
            measures: measures,
            beatsPerBar: runner.beats_per_bar,
            bpm: runner.bpm,
            lyricsLanguage: runner.language,
            key: runner.key
        )
    }

    private func run(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func readToEnd(_ fileHandle: FileHandle) async -> String {
        await Task.detached(priority: .utility) {
            let data = fileHandle.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
