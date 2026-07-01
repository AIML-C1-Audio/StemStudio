import SwiftUI

struct ProjectListView: View {
    @EnvironmentObject private var appState: AppState

    private var visibleProjects: [SongProject] {
        appState.projects(for: appState.selectedSection)
    }

    var body: some View {
        Group {
            if visibleProjects.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "music.note.house",
                    description: Text(emptyDescription)
                )
            } else {
                List(selection: $appState.selectedProjectID) {
                    ForEach(visibleProjects) { project in
                        ProjectRow(project: project)
                            .tag(project.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    appState.deleteProject(project.id)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle(appState.selectedSection.rawValue)
        .overlay {
            if appState.isImporting {
                ProgressView("Importing audio…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var emptyTitle: String {
        switch appState.selectedSection {
        case .processing: "No Active Processing"
        case .completed: "No Completed Projects"
        default: "No Projects"
        }
    }

    private var emptyDescription: String {
        switch appState.selectedSection {
        case .processing: "Projects currently running separation or score generation will appear here."
        case .completed: "Projects with generated sheet music will appear here."
        default: "Import an MP3 or WAV file to create your first project."
        }
    }
}

private struct ProjectRow: View {
    let project: SongProject

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: project.stage == .scoreReady ? "music.note.list" : "waveform")
                .font(.title3)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(project.stage.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(project.originalAudio.duration.stemStudioTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct EmptyProjectView: View {
    let importAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Start with a Song", systemImage: "waveform.badge.plus")
        } description: {
            Text("Import an MP3 or WAV file, separate its instruments, generate notation, and open practice mode.")
        } actions: {
            Button("Import Audio", action: importAction)
                .buttonStyle(.borderedProminent)
        }
    }
}
