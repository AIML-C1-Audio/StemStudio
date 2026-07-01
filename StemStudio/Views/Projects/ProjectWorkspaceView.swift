import SwiftUI

struct ProjectWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    let projectID: UUID

    @State private var selectedTab: WorkspaceTab = .stems

    private var project: SongProject? {
        appState.project(withID: projectID)
    }

    var body: some View {
        Group {
            if let project {
                VStack(spacing: 0) {
                    ProjectHeader(project: project)
                    Divider()

                    switch project.stage {
                    case .imported, .failed:
                        ProjectOverviewView(project: project)
                    case .separating:
                        SeparationProgressView(project: project, mode: .separation)
                    case .generatingScore:
                        SeparationProgressView(project: project, mode: .score)
                    case .separated, .scoreReady, .practicing:
                        workspace(project)
                    }
                }
                .navigationTitle(project.title)
            } else {
                ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
            }
        }
    }

    @ViewBuilder
    private func workspace(_ project: SongProject) -> some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $selectedTab) {
                Text("Stems").tag(WorkspaceTab.stems)
                Text("Sheet Music").tag(WorkspaceTab.score)
                    .disabled(project.latestScore == nil)
                Text("Practice").tag(WorkspaceTab.practice)
                    .disabled(project.latestScore == nil)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            .padding()

            Divider()

            switch selectedTab {
            case .stems:
                StemMixerView(project: project) {
                    selectedTab = .score
                }
            case .score:
                if let score = project.latestScore {
                    ScoreViewerView(project: project, score: score) {
                        selectedTab = .practice
                    }
                } else {
                    scoreUnavailable
                }
            case .practice:
                if let score = project.latestScore {
                    PracticeView(project: project, score: score)
                } else {
                    scoreUnavailable
                }
            }
        }
        .onChange(of: project.stage) { _, newValue in
            if newValue == .scoreReady {
                selectedTab = .score
            }
        }
    }

    private var scoreUnavailable: some View {
        ContentUnavailableView(
            "No Sheet Music Yet",
            systemImage: "music.note.list",
            description: Text("Choose a stem and generate sheet music first.")
        )
    }
}

private struct ProjectHeader: View {
    let project: SongProject

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .font(.title2.weight(.semibold))
                Text(project.originalAudio.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(stage: project.stage)
            TimeLabel(value: project.originalAudio.duration)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }
}
