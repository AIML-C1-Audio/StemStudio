import Foundation

private struct DemucsRunnerEvent: Decodable {
    let type: String
    let stage: String?
    let progress: Double?
    let message: String?
    let outputs: [String: String]?
}

enum DemucsProcessError: LocalizedError {
    case runtimeNotInstalled(String)
    case runnerNotFound(String)
    case processFailed(status: Int32, message: String)
    case runnerError(String)
    case missingCompletedEvent
    case missingStem(StemType)
    case missingStemFile(StemType, String)
    case ffmpegNotFound

    var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled(let path):
            return """
            Demucs runtime belum tersedia.

            Jalankan:
            ./Scripts/setup_demucs.sh

            Runtime yang dicari:
            \(path)
            """

        case .runnerNotFound(let path):
            return "demucs_runner.py tidak ditemukan di \(path)"

        case .processFailed(let status, let message):
            return """
            Demucs berhenti dengan exit code \(status).

            \(message)
            """

        case .runnerError(let message):
            return message

        case .missingCompletedEvent:
            return "Demucs selesai tanpa memberikan hasil output."

        case .missingStem(let stem):
            return "Output \(stem.rawValue) tidak diberikan oleh Demucs."

        case .missingStemFile(let stem, let path):
            return """
            File \(stem.rawValue) tidak ditemukan setelah separation.

            Path:
            \(path)
            """
            
        case .ffmpegNotFound:
            return """
            FFmpeg tidak ditemukan.

            Instal FFmpeg dengan:
            brew install ffmpeg

            Setelah itu tutup dan buka kembali Xcode.
            """
        }
    }
}

private enum DemucsDevelopmentRuntime {
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
            .appendingPathComponent("demucs")
            .appendingPathComponent("venv")
            .appendingPathComponent("bin")
            .appendingPathComponent("python")
    }

    static var runnerURL: URL {
        repositoryRootURL
            .appendingPathComponent("MLRuntime")
            .appendingPathComponent("Demucs")
            .appendingPathComponent("demucs_runner.py")
    }

    static var torchCacheURL: URL {
        repositoryRootURL
            .appendingPathComponent(".local")
            .appendingPathComponent("demucs")
            .appendingPathComponent("torch-cache")
    }
    
    private static func executableExists(
            named executableName: String
        ) -> Bool {
            let possibleDirectories = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ]

            return possibleDirectories.contains { directory in
                let executableURL = URL(fileURLWithPath: directory)
                    .appendingPathComponent(executableName)

                return FileManager.default.isExecutableFile(
                    atPath: executableURL.path
                )
            }
        }

    static func validate() throws {
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(
            atPath: pythonURL.path
        ) else {
            throw DemucsProcessError.runtimeNotInstalled(
                pythonURL.path
            )
        }

        guard fileManager.fileExists(
            atPath: runnerURL.path
        ) else {
            throw DemucsProcessError.runnerNotFound(
                runnerURL.path
            )
        }
        
        guard executableExists(named: "ffmpeg"),
              executableExists(named: "ffprobe") else {
            throw DemucsProcessError.ffmpegNotFound
        }
        
        try fileManager.createDirectory(
            at: torchCacheURL,
            withIntermediateDirectories: true
        )
    }
}

struct DemucsProcessService: StemSeparationService {
    func separate(
        sourceURL: URL,
        destinationDirectory: URL,
        duration: TimeInterval,
        progress: @escaping (Double, String) -> Void
    ) async throws -> [StemAsset] {
        let fileManager = FileManager.default

        guard fileManager.fileExists(
            atPath: sourceURL.path
        ) else {
            throw ServiceError.missingSource
        }

        try DemucsDevelopmentRuntime.validate()

        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        // Hapus hasil lama agar tidak dianggap sebagai output baru.
        for stem in StemType.allCases {
            let oldOutput = destinationDirectory
                .appendingPathComponent(stem.rawValue)
                .appendingPathExtension("wav")

            if fileManager.fileExists(atPath: oldOutput.path) {
                try fileManager.removeItem(at: oldOutput)
            }
        }

        progress(0.02, "Preparing Demucs runtime")

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL =
            DemucsDevelopmentRuntime.pythonURL

        process.arguments = [
            DemucsDevelopmentRuntime.runnerURL.path,
            "--input",
            sourceURL.path,
            "--output",
            destinationDirectory.path,
            "--device",
            "cpu"
        ]

        process.currentDirectoryURL =
            DemucsDevelopmentRuntime.repositoryRootURL

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment =
            ProcessInfo.processInfo.environment

        environment["TORCH_HOME"] =
            DemucsDevelopmentRuntime.torchCacheURL.path

        environment["PYTHONUNBUFFERED"] = "1"
        
        let requiredPaths = [
            "/opt/homebrew/bin",  // Homebrew Apple Silicon
            "/usr/local/bin",     // Homebrew Intel
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        
        let currentPath = environment["PATH"] ?? ""

        environment["PATH"] = (
            requiredPaths + [currentPath]
        )
        .filter { !$0.isEmpty }
        .joined(separator: ":")

        process.environment = environment

        async let terminationStatus = run(process)

        async let standardErrorText = readToEnd(
            errorPipe.fileHandleForReading
        )

        var completedEvent: DemucsRunnerEvent?
        var runnerErrorMessage: String?
        var diagnosticLines: [String] = []

        let decoder = JSONDecoder()

        for try await line in
            outputPipe.fileHandleForReading.bytes.lines
        {
            guard !line.isEmpty else {
                continue
            }

            guard
                let data = line.data(using: .utf8),
                let event = try? decoder.decode(
                    DemucsRunnerEvent.self,
                    from: data
                )
            else {
                diagnosticLines.append(line)
                continue
            }

            switch event.type {
            case "status":
                reportProgress(
                    stage: event.stage,
                    progress: progress
                )

            case "completed":
                completedEvent = event
                progress(1.0, "Stems ready")

            case "error":
                runnerErrorMessage =
                    event.message ?? "Demucs inference failed."

            case "cancelled":
                runnerErrorMessage =
                    event.message ?? "Separation was cancelled."
                
            case "progress":
                let inferenceProgress = min(
                    max(event.progress ?? 0, 0),
                    1
                )

                // 35% sampai 90% dialokasikan untuk inference.
                let overallProgress =
                    0.35 + (inferenceProgress * 0.55)

                progress(
                    overallProgress,
                    event.message
                        ?? "Separating instrument sources"
                )

            default:
                break
            }
        }

        let status = try await terminationStatus
        let standardError = await standardErrorText

        if let runnerErrorMessage {
            throw DemucsProcessError.runnerError(
                runnerErrorMessage
            )
        }

        guard status == 0 else {
            let diagnostics = [
                standardError,
                diagnosticLines.joined(separator: "\n")
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

            throw DemucsProcessError.processFailed(
                status: status,
                message: diagnostics.isEmpty
                    ? "No additional error information."
                    : diagnostics
            )
        }

        guard let completedEvent else {
            throw DemucsProcessError.missingCompletedEvent
        }

        return try makeStemAssets(
            from: completedEvent,
            duration: duration
        )
    }

    private func reportProgress(
        stage: String?,
        progress: @escaping (Double, String) -> Void
    ) {
        switch stage {
        case "loadingModel":
            progress(0.08, "Loading htdemucs_ft")

        case "loadingAudio":
            progress(0.20, "Preparing audio")

        case "separating":
            progress(0.35, "Separating instrument sources")

        case "saving":
            progress(0.92, "Saving stem audio")

        default:
            break
        }
    }

    private func makeStemAssets(
        from event: DemucsRunnerEvent,
        duration: TimeInterval
    ) throws -> [StemAsset] {
        guard let outputs = event.outputs else {
            throw DemucsProcessError.missingCompletedEvent
        }

        return try StemType.allCases.map { stemType in
            guard let outputPath = outputs[stemType.rawValue] else {
                throw DemucsProcessError.missingStem(stemType)
            }

            let outputURL = URL(
                fileURLWithPath: outputPath
            )

            guard FileManager.default.fileExists(
                atPath: outputURL.path
            ) else {
                throw DemucsProcessError.missingStemFile(
                    stemType,
                    outputURL.path
                )
            }

            return StemAsset(
                id: UUID(),
                type: stemType,
                relativePath: outputURL.path,
                duration: duration
            )
        }
    }

    private func run(
        _ process: Process
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation {
            continuation in

            process.terminationHandler = { finishedProcess in
                continuation.resume(
                    returning: finishedProcess.terminationStatus
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func readToEnd(
        _ fileHandle: FileHandle
    ) async -> String {
        await Task.detached(priority: .utility) {
            let data = fileHandle.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
