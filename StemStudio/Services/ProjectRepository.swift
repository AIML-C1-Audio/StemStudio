import Foundation

final class ProjectRepository {
    private let fileManager: FileManager
    let projectsRootURL: URL
    private let indexURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let root = appSupport
            .appendingPathComponent("StemStudio", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)

        projectsRootURL = root
        indexURL = root.appendingPathComponent("projects.json")

        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func loadProjects() throws -> [SongProject] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder.stemStudio.decode([SongProject].self, from: data)
    }

    func saveProjects(_ projects: [SongProject]) throws {
        let data = try JSONEncoder.stemStudio.encode(projects)
        try data.write(to: indexURL, options: .atomic)
    }

    func projectDirectory(for projectID: UUID) throws -> URL {
        let directory = projectsRootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func sourceDirectory(for projectID: UUID) throws -> URL {
        let directory = try projectDirectory(for: projectID)
            .appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func stemsDirectory(for projectID: UUID) throws -> URL {
        let directory = try projectDirectory(for: projectID)
            .appendingPathComponent("stems", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func relativePath(for url: URL) -> String {
        let rootPath = projectsRootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func resolve(_ relativePath: String) -> URL {
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: relativePath)
        }
        return projectsRootURL.appendingPathComponent(relativePath)
    }

    func deleteProject(_ project: SongProject) throws {
        let directory = projectsRootURL.appendingPathComponent(project.id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }
}

private extension JSONEncoder {
    static var stemStudio: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var stemStudio: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
