import SwiftUI

struct ProjectOverviewView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var player = SingleAudioPlayer()

    let project: SongProject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard("Original Audio", subtitle: "Review the imported song before processing.") {
                    WaveformPlaceholder(seed: project.title.hashValue)

                    HStack(spacing: 12) {
                        Button {
                            player.toggle()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 18)
                        }
                        .buttonStyle(.borderedProminent)

                        TimeLabel(value: player.currentTime)
                        Slider(
                            value: Binding(
                                get: { player.currentTime },
                                set: { player.seek(to: $0) }
                            ),
                            in: 0...max(player.duration, 1)
                        )
                        TimeLabel(value: player.duration)
                    }
                }

                SectionCard("Processing Pipeline", subtitle: "The machine-learning services are replaceable adapters.") {
                    PipelineRow(title: "Audio imported", systemImage: "checkmark.circle.fill", completed: true)
                    PipelineRow(title: "Separate instruments", systemImage: "waveform.path.ecg", completed: false)
                    PipelineRow(title: "Generate sheet music", systemImage: "music.note.list", completed: false)
                    PipelineRow(title: "Practice with live recognition", systemImage: "music.mic", completed: false)
                }

                HStack {
                    Spacer()
                    Button("Separate Instruments") {
                        Task { await appState.startSeparation(projectID: project.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .task {
            do {
                try player.load(url: appState.resolve(project.originalAudio.relativePath))
            } catch {
                appState.alertMessage = "Audio preview could not be loaded: \(error.localizedDescription)"
            }
        }
        .onDisappear { player.stop() }
    }
}

private struct PipelineRow: View {
    let title: String
    let systemImage: String
    let completed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(completed ? .primary : .secondary)
                .frame(width: 22)
            Text(title)
            Spacer()
            Text(completed ? "Done" : "Pending")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
