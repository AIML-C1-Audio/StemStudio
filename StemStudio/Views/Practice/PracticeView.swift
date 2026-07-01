import AppKit
import SwiftUI

struct PracticeView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var microphone = MicrophoneMonitor()
    @StateObject private var recognition = MockLiveRecognitionService()

    let project: SongProject
    let score: ScoreAsset

    @State private var startedAt: Date?
    @State private var lastDuration: TimeInterval = 0
    @State private var showSummary = false

    private var expectedNote: NoteEvent? {
        guard !score.notes.isEmpty else { return nil }
        return score.notes[min(recognition.noteIndex, score.notes.count - 1)]
    }

    private var isCorrect: Bool {
        expectedNote?.pitch == recognition.detectedPitch
    }

    var body: some View {
        Group {
            if showSummary {
                PracticeSummaryView(
                    project: project,
                    score: score,
                    duration: lastDuration,
                    accuracy: 0.8,
                    practiceAgain: {
                        showSummary = false
                        Task { await startPractice() }
                    }
                )
            } else {
                practiceWorkspace
            }
        }
        .onDisappear {
            microphone.stop()
            recognition.stop()
        }
    }

    private var practiceWorkspace: some View {
        ScrollView {
            VStack(spacing: 20) {
                if microphone.permissionState == .denied {
                    permissionCard
                } else {
                    liveStatusCard
                    noteTimeline
                    controls
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .task {
            if startedAt == nil {
                await startPractice()
            }
        }
    }

    private var liveStatusCard: some View {
        SectionCard("Live Practice", subtitle: "Microphone audio is active; note recognition is mocked for UI development.") {
            HStack(spacing: 24) {
                notePanel(title: "Expected", value: expectedNote?.pitch ?? "—")
                Image(systemName: isCorrect ? "equal.circle.fill" : "arrow.right.circle")
                    .font(.title)
                    .foregroundStyle(isCorrect ? .green : .secondary)
                notePanel(title: "Detected", value: recognition.detectedPitch)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Microphone input")
                    Spacer()
                    Text(microphone.isRunning ? "Listening" : "Starting…")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                LevelMeter(level: microphone.level)
            }

            HStack {
                Label(
                    isCorrect ? "Correct note" : "Keep playing",
                    systemImage: isCorrect ? "checkmark.circle.fill" : "ear"
                )
                .foregroundStyle(isCorrect ? .green : .secondary)

                Spacer()

                Text("Confidence \(recognition.confidence.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var noteTimeline: some View {
        SectionCard("Current Phrase", subtitle: "The active note is highlighted using its stable note ID.") {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(score.notes.prefix(24).enumerated()), id: \.offset) { index, note in
                        VStack(spacing: 6) {
                            Text("♩")
                                .font(.title2)
                            Text(note.pitch)
                                .font(.caption.bold())
                        }
                        .frame(width: 58, height: 66)
                        .background(
                            index == recognition.noteIndex ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var controls: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                Label(elapsed.stemStudioTime, systemImage: "timer")
                    .monospacedDigit()
            }

            Spacer()

            Button("Restart") {
                recognition.start(notes: score.notes)
                startedAt = Date()
            }

            Button("Stop Practice", role: .destructive) {
                finishPractice()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var permissionCard: some View {
        SectionCard("Microphone Access Required", subtitle: "Enable microphone access to use live practice mode.") {
            Text("Open System Settings → Privacy & Security → Microphone, then allow StemStudio.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("Try Again") {
                    Task { await startPractice() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func notePanel(title: String, value: String) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .frame(minWidth: 140)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func startPractice() async {
        await microphone.requestAndStart()
        guard microphone.permissionState == .authorized else { return }
        recognition.start(notes: score.notes)
        startedAt = Date()
    }

    private func finishPractice() {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        lastDuration = elapsed
        let total = max(1, min(score.notes.count, recognition.noteIndex + 1))
        let correct = max(1, Int(Double(total) * 0.8))

        microphone.stop()
        recognition.stop()
        appState.finishPractice(
            projectID: project.id,
            total: total,
            correct: correct,
            duration: elapsed
        )
        startedAt = nil
        showSummary = true
    }
}

private struct PracticeSummaryView: View {
    let project: SongProject
    let score: ScoreAsset
    let duration: TimeInterval
    let accuracy: Double
    let practiceAgain: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 58))
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text("Practice Complete")
                    .font(.largeTitle.bold())
                Text("\(project.title) · \(score.instrument.title)")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                summaryMetric(title: "Duration", value: duration.stemStudioTime)
                summaryMetric(title: "Accuracy", value: accuracy.formatted(.percent.precision(.fractionLength(0))))
                summaryMetric(title: "Instrument", value: score.instrument.title)
            }
            .frame(maxWidth: 620)

            Button("Practice Again", action: practiceAgain)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Spacer()
        }
        .padding(40)
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
