import AVFAudio
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [SongProject] = []
    @Published var selectedProjectID: UUID?
    @Published var selectedSection: SidebarSection = .projects
    @Published var processing: [UUID: ProcessingStatus] = [:]
    @Published var alertMessage: String?
    @Published var isImporting = false

    let repository: ProjectRepository
    private let separationService: any StemSeparationService
    private let scoreService: any ScoreGenerationService

    init(
        repository: ProjectRepository = ProjectRepository(),
        separationService: any StemSeparationService = DemucsProcessService(),
        scoreService: any ScoreGenerationService = MockScoreGenerationService()
    ) {
        self.repository = repository
        self.separationService = separationService
        self.scoreService = scoreService

        loadProjects()
    }

    var selectedProject: SongProject? {
        guard let selectedProjectID else {
            return nil
        }

        return projects.first {
            $0.id == selectedProjectID
        }
    }

    func projects(
        for section: SidebarSection
    ) -> [SongProject] {
        switch section {
        case .projects:
            return projects

        case .processing:
            return projects.filter {
                [
                    .separating,
                    .generatingScore,
                    .practicing
                ].contains($0.stage)
            }

        case .completed:
            return projects.filter {
                $0.stage == .scoreReady
            }

        case .settings:
            return []
        }
    }

    func project(
        withID id: UUID
    ) -> SongProject? {
        projects.first {
            $0.id == id
        }
    }

    func resolve(
        _ relativePath: String
    ) -> URL {
        repository.resolve(relativePath)
    }

    func importAudio(
        from sourceURL: URL
    ) async {
        isImporting = true

        defer {
            isImporting = false
        }

        let didAccess =
            sourceURL.startAccessingSecurityScopedResource()

        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let projectID = UUID()

            let sourceDirectory =
                try repository.sourceDirectory(
                    for: projectID
                )

            let fileExtension =
                sourceURL.pathExtension.lowercased()

            let destinationURL = sourceDirectory
                .appendingPathComponent("original")
                .appendingPathExtension(
                    fileExtension.isEmpty
                        ? "wav"
                        : fileExtension
                )

            if FileManager.default.fileExists(
                atPath: destinationURL.path
            ) {
                try FileManager.default.removeItem(
                    at: destinationURL
                )
            }

            try FileManager.default.copyItem(
                at: sourceURL,
                to: destinationURL
            )

            let audioPlayer = try AVAudioPlayer(
                contentsOf: destinationURL
            )

            let duration = audioPlayer.duration

            let format: AudioFormat

            switch fileExtension {
            case "mp3":
                format = .mp3

            case "wav", "wave":
                format = .wav

            default:
                format = .other
            }

            let now = Date()

            let audio = AudioAsset(
                id: UUID(),
                fileName: sourceURL.lastPathComponent,
                relativePath: repository.relativePath(
                    for: destinationURL
                ),
                duration: duration,
                format: format
            )

            let project = SongProject(
                id: projectID,
                title: sourceURL
                    .deletingPathExtension()
                    .lastPathComponent,
                createdAt: now,
                updatedAt: now,
                originalAudio: audio,
                stems: [],
                scores: [],
                practiceSessions: [],
                stage: .imported
            )

            projects.insert(project, at: 0)

            selectedProjectID = project.id
            selectedSection = .projects

            try persist()

        } catch {
            alertMessage =
                "Audio could not be imported: "
                + error.localizedDescription
        }
    }

    func startSeparation(
        projectID: UUID
    ) async {
        guard let index = projects.firstIndex(
            where: { $0.id == projectID }
        ) else {
            return
        }

        projects[index].stage = .separating
        projects[index].updatedAt = Date()

        processing[projectID] = ProcessingStatus(
            progress: 0,
            message: "Queued"
        )

        try? persist()

        let sourceURL = resolve(
            projects[index].originalAudio.relativePath
        )

        do {
            let stemsDirectory =
                try repository.stemsDirectory(
                    for: projectID
                )

            let duration =
                projects[index].originalAudio.duration

            let repository = repository

            let stems = try await separationService.separate(
                sourceURL: sourceURL,
                destinationDirectory: stemsDirectory,
                duration: duration
            ) { [weak self] progressValue, message in
                Task { @MainActor [weak self] in
                    await Task.yield()

                    self?.processing[projectID] =
                        ProcessingStatus(
                            progress: progressValue,
                            message: message
                        )
                }
            }

            guard let freshIndex = projects.firstIndex(
                where: { $0.id == projectID }
            ) else {
                return
            }

            projects[freshIndex].stems = stems.map { stem in
                var copy = stem

                copy.relativePath = repository.relativePath(
                    for: URL(
                        fileURLWithPath: stem.relativePath
                    )
                )

                return copy
            }

            projects[freshIndex].stage = .separated
            projects[freshIndex].updatedAt = Date()

            processing[projectID] = nil

            try persist()

        } catch {
            markFailure(
                projectID: projectID,
                message:
                    "Instrument separation failed: "
                    + error.localizedDescription
            )
        }
    }
    
    func generateScore(
        projectID: UUID,
        stemID: UUID
    ) async {
        guard let projectIndex = projects.firstIndex(
            where: { $0.id == projectID }
        ),
        let stem = projects[projectIndex].stems.first(
            where: { $0.id == stemID }
        ) else {
            alertMessage =
                ServiceError
                    .noStemSelected
                    .localizedDescription

            return
        }

        let stemURL = resolve(
            stem.relativePath
        ).standardizedFileURL

        debugSheetMusicHandoff(
            projectID: projectID,
            stem: stem,
            stemURL: stemURL
        )

        let fileManager = FileManager.default

        guard fileManager.fileExists(
            atPath: stemURL.path
        ) else {
            alertMessage = """
            Sheet music input file was not found.

            Stem: \(stem.type.title)
            Stored path: \(stem.relativePath)
            Resolved path: \(stemURL.path)
            """

            return
        }

        guard fileManager.isReadableFile(
            atPath: stemURL.path
        ) else {
            alertMessage = """
            Sheet music input file cannot be read.

            Stem: \(stem.type.title)
            Resolved path: \(stemURL.path)
            """

            return
        }

        projects[projectIndex].stage =
            .generatingScore

        projects[projectIndex].updatedAt =
            Date()

        processing[projectID] = ProcessingStatus(
            progress: 0,
            message: "Queued"
        )

        try? persist()

        do {
            let score =
                try await scoreService.generateScore(
                    from: stem,
                    audioURL: stemURL
                ) { [weak self] progressValue, message in
                    Task { @MainActor [weak self] in
                        await Task.yield()

                        self?.processing[projectID] =
                            ProcessingStatus(
                                progress: progressValue,
                                message: message
                            )
                    }
                }

            guard let freshIndex =
                projects.firstIndex(
                    where: { $0.id == projectID }
                )
            else {
                return
            }

            projects[freshIndex].scores.append(score)
            projects[freshIndex].stage = .scoreReady
            projects[freshIndex].updatedAt = Date()

            processing[projectID] = nil

            try persist()

        } catch {
            markFailure(
                projectID: projectID,
                message:
                    "Sheet music generation failed: "
                    + error.localizedDescription
            )
        }
    }

    func updateStem(
        projectID: UUID,
        stemID: UUID,
        volume: Double? = nil,
        muted: Bool? = nil,
        solo: Bool? = nil
    ) {
        guard let projectIndex = projects.firstIndex(
            where: { $0.id == projectID }
        ),
        let stemIndex =
            projects[projectIndex].stems.firstIndex(
                where: { $0.id == stemID }
            )
        else {
            return
        }

        if let volume {
            projects[projectIndex]
                .stems[stemIndex]
                .volume = volume
        }

        if let muted {
            projects[projectIndex]
                .stems[stemIndex]
                .isMuted = muted
        }

        if let solo {
            projects[projectIndex]
                .stems[stemIndex]
                .isSolo = solo
        }

        projects[projectIndex].updatedAt = Date()

        try? persist()
    }

    // MARK: - Practice

    func finishPractice(
        projectID: UUID,
        total: Int,
        correct: Int,
        duration: TimeInterval
    ) {
        guard let index = projects.firstIndex(
            where: { $0.id == projectID }
        ) else {
            return
        }

        let session = PracticeSession(
            id: UUID(),
            createdAt: Date(),
            duration: duration,
            totalExpectedNotes: total,
            correctNotes: correct,
            missedNotes: max(0, total - correct)
        )

        projects[index]
            .practiceSessions
            .append(session)

        projects[index].stage = .scoreReady
        projects[index].updatedAt = Date()

        try? persist()
    }

    func deleteProject(
        _ projectID: UUID
    ) {
        guard let project = project(
            withID: projectID
        ) else {
            return
        }

        do {
            try repository.deleteProject(project)

            projects.removeAll {
                $0.id == projectID
            }

            if selectedProjectID == projectID {
                selectedProjectID =
                    projects.first?.id
            }

            try persist()

        } catch {
            alertMessage =
                "Project could not be deleted: "
                + error.localizedDescription
        }
    }

    private func debugSheetMusicHandoff(
        projectID: UUID,
        stem: StemAsset,
        stemURL: URL
    ) {
        let fileManager = FileManager.default

        let exists = fileManager.fileExists(
            atPath: stemURL.path
        )

        let readable = fileManager.isReadableFile(
            atPath: stemURL.path
        )

        var fileSizeDescription = "Unavailable"

        if let attributes =
            try? fileManager.attributesOfItem(
                atPath: stemURL.path
            ),
        let fileSize =
            attributes[.size] as? NSNumber {
            fileSizeDescription =
                "\(fileSize.int64Value) bytes"
        }

        print(
            """

            ========== SHEET MUSIC HANDOFF ==========
            Project ID       : \(projectID)
            Stem ID          : \(stem.id)
            Stem type        : \(stem.type.rawValue)
            Stored path      : \(stem.relativePath)
            Resolved URL     : \(stemURL.absoluteString)
            Resolved path    : \(stemURL.path)
            Path extension   : \(stemURL.pathExtension)
            Is file URL      : \(stemURL.isFileURL)
            File exists      : \(exists)
            File readable    : \(readable)
            File size        : \(fileSizeDescription)
            Stored duration  : \(stem.duration) seconds
            =========================================

            """
        )

        guard exists else {
            print(
                "❌ Sheet music handoff failed: "
                + "stem file does not exist."
            )

            return
        }

        do {
            let audioFile = try AVAudioFile(
                forReading: stemURL
            )

            let sampleRate =
                audioFile.processingFormat.sampleRate

            let channelCount =
                audioFile.processingFormat.channelCount

            let frameCount =
                audioFile.length

            let measuredDuration: Double

            if sampleRate > 0 {
                measuredDuration =
                    Double(frameCount) / sampleRate
            } else {
                measuredDuration = 0
            }

            print(
                """
                ✅ Audio file successfully opened.
                Sample rate       : \(sampleRate)
                Channels          : \(channelCount)
                Frames            : \(frameCount)
                Measured duration : \(measuredDuration) seconds
                """
            )

        } catch {
            print(
                """
                ❌ Audio file exists, but AVAudioFile could not open it.
                Error: \(error.localizedDescription)
                """
            )
        }
    }
    
    private func markFailure(
        projectID: UUID,
        message: String
    ) {
        if let index = projects.firstIndex(
            where: { $0.id == projectID }
        ) {
            projects[index].stage = .failed
            projects[index].updatedAt = Date()
        }

        processing[projectID] = nil
        alertMessage = message

        try? persist()
    }

    private func loadProjects() {
        do {
            projects = try repository
                .loadProjects()
                .sorted {
                    $0.updatedAt > $1.updatedAt
                }

            selectedProjectID =
                projects.first?.id

        } catch {
            alertMessage =
                "Saved projects could not be loaded: "
                + error.localizedDescription
        }
    }

    private func persist() throws {
        try repository.saveProjects(projects)
    }
}
