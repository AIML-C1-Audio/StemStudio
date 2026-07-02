import Foundation

protocol StemSeparationService {
    func separate(
        sourceURL: URL,
        destinationDirectory: URL,
        duration: TimeInterval,
        progress: @escaping (Double, String) -> Void
    ) async throws -> [StemAsset]
}

protocol ScoreGenerationService {
    func generateScore(
        from stem: StemAsset,
        audioURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws -> ScoreAsset
}

enum ServiceError: LocalizedError {
    case missingSource
    case noStemSelected
    case scoreUnavailable

    var errorDescription: String? {
        switch self {
        case .missingSource: "The source audio file could not be found."
        case .noStemSelected: "Choose an instrument before generating sheet music."
        case .scoreUnavailable: "Sheet music is not available for this project yet."
        }
    }
}

struct MockStemSeparationService: StemSeparationService {
    func separate(
        sourceURL: URL,
        destinationDirectory: URL,
        duration: TimeInterval,
        progress: @escaping (Double, String) -> Void
    ) async throws -> [StemAsset] {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ServiceError.missingSource
        }

        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let steps: [(Double, String)] = [
            (0.08, "Preparing audio"),
            (0.24, "Loading Demucs model"),
            (0.52, "Separating instrument sources"),
            (0.78, "Normalizing stem output"),
            (0.94, "Saving audio files")
        ]

        for step in steps {
            progress(step.0, step.1)
            try await Task.sleep(for: .milliseconds(420))
        }

        let sourceExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        var stems: [StemAsset] = []

        for type in StemType.allCases {
            let outputURL = destinationDirectory
                .appendingPathComponent(type.rawValue)
                .appendingPathExtension(sourceExtension)

            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            // Mock only: duplicate the source so UI and playback can be tested.
            // Replace this implementation with the actual Demucs adapter.
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)

            stems.append(
                StemAsset(
                    id: UUID(),
                    type: type,
                    relativePath: outputURL.path,
                    duration: duration
                )
            )
        }

        progress(1.0, "Stems ready")
        return stems
    }
}

struct MockScoreGenerationService: ScoreGenerationService {
    func generateScore(
        from stem: StemAsset,
        audioURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws -> ScoreAsset {
        
        print("""
                
                ===== SCORE SERVICE RECEIVED =====
                Stem ID       : \(stem.id)
                Stem type     : \(stem.type.rawValue)
                Stored path   : \(stem.relativePath)
                Audio URL     : \(audioURL.absoluteString)
                Audio path    : \(audioURL.path)
                File exists   : \(FileManager.default.fileExists(atPath: audioURL.path))
                File readable : \(FileManager.default.isReadableFile(atPath: audioURL.path))
                ==================================
                
                """)
        
        let steps: [(Double, String)] = [
            (0.12, "Loading \(stem.type.title) stem"),
            (0.35, "Detecting pitches"),
            (0.62, "Estimating rhythm"),
            (0.82, "Building notation"),
            (0.96, "Saving score")
        ]

        for step in steps {
            progress(step.0, step.1)
            try await Task.sleep(for: .milliseconds(320))
        }

        let pitches: [(String, Int)] = [
            ("E2", 40), ("G2", 43), ("A2", 45), ("B2", 47),
            ("D3", 50), ("E3", 52), ("G3", 55), ("A3", 57)
        ]

        let count = max(16, min(64, Int(stem.duration / 2.0)))
        let notes = (0..<count).map { index in
            let pitch = pitches[index % pitches.count]
            return NoteEvent(
                id: UUID(),
                pitch: pitch.0,
                midi: pitch.1,
                startTime: Double(index) * 1.5,
                duration: index.isMultiple(of: 4) ? 1.5 : 0.75,
                confidence: 0.82 + Double(index % 12) / 100
            )
        }

        progress(1.0, "Sheet music ready")
        return ScoreAsset(
            id: UUID(),
            stemID: stem.id,
            instrument: stem.type,
            createdAt: Date(),
            notes: notes
        )
    }
}
