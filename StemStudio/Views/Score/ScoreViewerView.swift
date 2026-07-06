import SwiftUI

struct ScoreViewerView: View {
    let project: SongProject
    let score: ScoreAsset
    let startPractice: () -> Void

    @State private var zoom = 1.0

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if score.isRealScore {
                ScoreNotationView(score: score, zoom: zoom)
            } else {
                DummyStaffView(notes: score.notes, zoom: zoom)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(score.instrument.title) Sheet")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("Generated \(score.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    if score.isRealScore {
                        if let bpm = score.bpm {
                            Text("· \(Int(bpm)) BPM")
                        }
                        if let bpb = score.beatsPerBar {
                            Text("· \(bpb)/4")
                        }
                        if let lang = score.lyricsLanguage {
                            Text("· lyrics: \(lang)")
                        }
                    }
                }
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
    }
}

// MARK: - Fallback rendering for dummy/mock scores

private struct DummyStaffView: View {
    let notes: [NoteEvent]
    let zoom: Double

    private var measures: [[NoteEvent]] {
        stride(from: 0, to: notes.count, by: 8).map { start in
            Array(notes[start..<min(start + 8, notes.count)])
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 20) {
                ForEach(Array(measures.enumerated()), id: \.offset) { index, notes in
                    DummyMeasureView(number: index + 1, notes: notes)
                }
            }
            .scaleEffect(zoom, anchor: .topLeading)
            .padding(34)
            .frame(minWidth: 760, alignment: .topLeading)
        }
        .background(.white.opacity(0.92))
    }
}

private struct DummyMeasureView: View {
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
