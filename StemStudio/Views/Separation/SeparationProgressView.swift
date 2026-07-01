import SwiftUI

struct SeparationProgressView: View {
    enum Mode {
        case separation
        case score

        var title: String {
            switch self {
            case .separation: "Separating Instruments"
            case .score: "Generating Sheet Music"
            }
        }

        var description: String {
            switch self {
            case .separation: "The mock Demucs adapter is creating vocals, drums, bass, and other stems."
            case .score: "The mock transcription adapter is creating timed notes for the selected instrument."
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    let project: SongProject
    let mode: Mode

    private var status: ProcessingStatus {
        appState.processing[project.id] ?? ProcessingStatus(progress: 0.03, message: "Starting")
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: mode == .separation ? "waveform.path.ecg" : "music.note.list")
                .font(.system(size: 52))
                .symbolEffect(.pulse)

            VStack(spacing: 7) {
                Text(mode.title)
                    .font(.title.bold())
                Text(mode.description)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(alignment: .leading, spacing: 9) {
                ProgressView(value: status.progress)
                HStack {
                    Text(status.message)
                    Spacer()
                    Text(status.progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560)

            Text("This screen remains responsive while processing runs asynchronously.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(40)
    }
}
