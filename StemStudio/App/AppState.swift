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
        separationService: any StemSeparationService = MockStemSeparationService(),
        scoreService: any ScoreGenerationService = MockScoreGenerationService()
    ) {
        self.repository = repository
        self.separationService = separationService
        self.scoreService = scoreService
        loadProjects()
    }

    var selectedProject: SongProject? {
        guard let selectedProjectID else { return nil }
        return projects.first(where: { $0.id == selectedProjectID })
    }

    func projects(for section: SidebarSection) -> [SongProject] {
        switch section {
        case .projects:
            projects
        case .processing:
            projects.filter { [.separating, .generatingScore, .practicing].contains($0.stage) }
        case .completed:
            projects.filter { $0.stage == .scoreReady }
        case .settings:
            []
        }
    }

    func project(withID id: UUID) -> SongProject? {
        projects.first(where: { $0.id == id })
    }

    func resolve(_ relativePath: String) -> URL {
        repository.resolve(relativePath)
    }

    func importAudio(from sourceURL: URL) async {
        isImporting = true
        defer { isImporting = false }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let projectID = UUID()
            let sourceDirectory = try repository.sourceDirectory(for: projectID)
            let ext = sourceURL.pathExtension.lowercased()
            let destinationURL = sourceDirectory
                .appendingPathComponent("original")
                .appendingPathExtension(ext.isEmpty ? "wav" : ext)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let audioPlayer = try AVAudioPlayer(contentsOf: destinationURL)
            let duration = audioPlayer.duration
            let format: AudioFormat = switch ext {
            case "mp3": .mp3
            case "wav", "wave": .wav
            default: .other
            }

            let now = Date()
            let audio = AudioAsset(
                id: UUID(),
                fileName: sourceURL.lastPathComponent,
                relativePath: repository.relativePath(for: destinationURL),
                duration: duration,
                format: format
            )

            let project = SongProject(
                id: projectID,
                title: sourceURL.deletingPathExtension().lastPathComponent,
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
            alertMessage = "Audio could not be imported: \(error.localizedDescription)"
        }
    }

    func startSeparation(projectID: UUID) async {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }

        projects[index].stage = .separating
        projects[index].updatedAt = Date()
        processing[projectID] = ProcessingStatus(progress: 0, message: "Queued")
        try? persist()

        let sourceURL = resolve(projects[index].originalAudio.relativePath)

        do {
            let stemsDirectory = try repository.stemsDirectory(for: projectID)
            let duration = projects[index].originalAudio.duration
            let repository = repository

            let stems = try await separationService.separate(
                sourceURL: sourceURL,
                destinationDirectory: stemsDirectory,
                duration: duration
            ) { [weak self] progress, message in
                Task { @MainActor in
                    self?.processing[projectID] = ProcessingStatus(progress: progress, message: message)
                }
            }

            guard let freshIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
            projects[freshIndex].stems = stems.map { stem in
                var copy = stem
                copy.relativePath = repository.relativePath(for: URL(fileURLWithPath: stem.relativePath))
                return copy
            }
            projects[freshIndex].stage = .separated
            projects[freshIndex].updatedAt = Date()
            processing[projectID] = nil
            try persist()
        } catch {
            markFailure(projectID: projectID, message: "Instrument separation failed: \(error.localizedDescription)")
        }
    }

    func generateScore(projectID: UUID, stemID: UUID) async {
        guard
            let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
            let stem = projects[projectIndex].stems.first(where: { $0.id == stemID })
        else {
            alertMessage = ServiceError.noStemSelected.localizedDescription
            return
        }

        projects[projectIndex].stage = .generatingScore
        projects[projectIndex].updatedAt = Date()
        processing[projectID] = ProcessingStatus(progress: 0, message: "Queued")
        try? persist()

        do {
            let score = try await scoreService.generateScore(from: stem) { [weak self] progress, message in
                Task { @MainActor in
                    self?.processing[projectID] = ProcessingStatus(progress: progress, message: message)
                }
            }

            guard let freshIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
            projects[freshIndex].scores.append(score)
            projects[freshIndex].stage = .scoreReady
            projects[freshIndex].updatedAt = Date()
            processing[projectID] = nil
            try persist()
        } catch {
            markFailure(projectID: projectID, message: "Sheet music generation failed: \(error.localizedDescription)")
        }
    }

    func updateStem(
        projectID: UUID,
        stemID: UUID,
        volume: Double? = nil,
        muted: Bool? = nil,
        solo: Bool? = nil
    ) {
        guard
            let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
            let stemIndex = projects[projectIndex].stems.firstIndex(where: { $0.id == stemID })
        else { return }

        if let volume { projects[projectIndex].stems[stemIndex].volume = volume }
        if let muted { projects[projectIndex].stems[stemIndex].isMuted = muted }
        if let solo { projects[projectIndex].stems[stemIndex].isSolo = solo }
        projects[projectIndex].updatedAt = Date()
        try? persist()
    }

    func finishPractice(projectID: UUID, total: Int, correct: Int, duration: TimeInterval) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }

        let session = PracticeSession(
            id: UUID(),
            createdAt: Date(),
            duration: duration,
            totalExpectedNotes: total,
            correctNotes: correct,
            missedNotes: max(0, total - correct)
        )
        projects[index].practiceSessions.append(session)
        projects[index].stage = .scoreReady
        projects[index].updatedAt = Date()
        try? persist()
    }

    func deleteProject(_ projectID: UUID) {
        guard let project = project(withID: projectID) else { return }
        do {
            try repository.deleteProject(project)
            projects.removeAll(where: { $0.id == projectID })
            if selectedProjectID == projectID {
                selectedProjectID = projects.first?.id
            }
            try persist()
        } catch {
            alertMessage = "Project could not be deleted: \(error.localizedDescription)"
        }
    }

    private func markFailure(projectID: UUID, message: String) {
        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].stage = .failed
            projects[index].updatedAt = Date()
        }
        processing[projectID] = nil
        alertMessage = message
        try? persist()
    }

    private func loadProjects() {
        do {
            projects = try repository.loadProjects().sorted(by: { $0.updatedAt > $1.updatedAt })
            selectedProjectID = projects.first?.id
        } catch {
            alertMessage = "Saved projects could not be loaded: \(error.localizedDescription)"
        }
    }

    private func persist() throws {
        try repository.saveProjects(projects)
    }
}
