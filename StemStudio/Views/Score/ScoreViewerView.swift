import SwiftUI

struct ScoreViewerView: View {
    let project: SongProject
    let score: ScoreAsset
    let startPractice: () -> Void

    @State private var zoom = 1.0

    private var measures: [[NoteEvent]] {
        stride(from: 0, to: score.notes.count, by: 8).map { start in
            Array(score.notes[start..<min(start + 8, score.notes.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(score.instrument.title) Sheet")
                        .font(.headline)
                    Text("Generated \(score.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    zoom = max(0.7, zoom - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }

                Text(zoom.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48)

                Button {
                    zoom = min(1.6, zoom + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }

                Button("Start Practice", action: startPractice)
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 20) {
                    ForEach(Array(measures.enumerated()), id: \.offset) { index, notes in
                        MeasureView(number: index + 1, notes: notes)
                    }
                }
                .scaleEffect(zoom, anchor: .topLeading)
                .padding(34)
                .frame(minWidth: 760, alignment: .topLeading)
            }
            .background(.white.opacity(0.92))
        }
    }
}

private struct MeasureView: View {
    let number: Int
    let notes: [NoteEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measure \(number)")
                .font(.caption)
                .foregroundStyle(.gray)

            ZStack {
                VStack(spacing: 10) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle()
                            .fill(.black.opacity(0.65))
                            .frame(height: 1)
                    }
                }

                HStack(spacing: 28) {
                    ForEach(notes) { note in
                        VStack(spacing: 5) {
                            Text("♩")
                                .font(.system(size: 32))
                                .foregroundStyle(.black)
                            Text(note.pitch)
                                .font(.caption.bold())
                                .foregroundStyle(.black)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(width: 720, height: 92)
            .padding(.vertical, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(.black).frame(width: 2)
            }
            .overlay(alignment: .trailing) {
                Rectangle().fill(.black).frame(width: 2)
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}
