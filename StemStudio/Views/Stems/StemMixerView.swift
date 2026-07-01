import SwiftUI

struct StemMixerView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var audio = StemMixerAudioController()

    let project: SongProject
    let onScoreGenerated: () -> Void

    @State private var selectedStemID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionCard("Stem Mixer", subtitle: "Play all stems in sync, then mute, solo, or change their volume.") {
                        VStack(spacing: 0) {
                            ForEach(project.stems) { stem in
                                StemTrackRow(
                                    stem: stem,
                                    isSelected: selectedStemID == stem.id,
                                    select: { selectedStemID = stem.id },
                                    setVolume: { value in
                                        appState.updateStem(projectID: project.id, stemID: stem.id, volume: value)
                                        audio.applyMix(stems: refreshedStems)
                                    },
                                    toggleMute: {
                                        appState.updateStem(
                                            projectID: project.id,
                                            stemID: stem.id,
                                            muted: !stem.isMuted
                                        )
                                        audio.applyMix(stems: refreshedStems)
                                    },
                                    toggleSolo: {
                                        appState.updateStem(
                                            projectID: project.id,
                                            stemID: stem.id,
                                            solo: !stem.isSolo
                                        )
                                        audio.applyMix(stems: refreshedStems)
                                    }
                                )

                                if stem.id != project.stems.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }

                    SectionCard("Generate Sheet Music", subtitle: "Select one stem to send to the transcription service.") {
                        Picker("Instrument", selection: $selectedStemID) {
                            Text("Choose a stem").tag(UUID?.none)
                            ForEach(project.stems) { stem in
                                Text(stem.type.title).tag(Optional(stem.id))
                            }
                        }
                        .pickerStyle(.menu)

                        HStack {
                            Label(
                                "Output: timed-note score (mock)",
                                systemImage: "doc.text.magnifyingglass"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                            Spacer()

                            Button("Generate Sheet Music") {
                                guard let selectedStemID else {
                                    appState.alertMessage = ServiceError.noStemSelected.localizedDescription
                                    return
                                }
                                Task {
                                    await appState.generateScore(
                                        projectID: project.id,
                                        stemID: selectedStemID
                                    )
                                    onScoreGenerated()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedStemID == nil)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 950)
                .frame(maxWidth: .infinity)
            }

            Divider()

            transport
        }
        .task {
            selectedStemID = selectedStemID ?? project.stems.first?.id
            audio.load(stems: project.stems) { stem in
                appState.resolve(stem.relativePath)
            }
        }
        .onDisappear { audio.stop() }
    }

    private var refreshedStems: [StemAsset] {
        appState.project(withID: project.id)?.stems ?? project.stems
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                audio.toggle(stems: refreshedStems)
            } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderedProminent)

            TimeLabel(value: audio.currentTime)

            Slider(
                value: Binding(
                    get: { audio.currentTime },
                    set: { audio.seek(to: $0, stems: refreshedStems) }
                ),
                in: 0...max(audio.duration, 1)
            )

            TimeLabel(value: audio.duration)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

private struct StemTrackRow: View {
    let stem: StemAsset
    let isSelected: Bool
    let select: () -> Void
    let setVolume: (Double) -> Void
    let toggleMute: () -> Void
    let toggleSolo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                Image(systemName: stem.type.systemImage)
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(isSelected ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Text(stem.type.title)
                .fontWeight(.medium)
                .frame(width: 72, alignment: .leading)

            WaveformPlaceholder(seed: stem.type.rawValue.hashValue)
                .frame(maxWidth: .infinity)

            Button("M") {
                toggleMute()
            }
            .buttonStyle(.bordered)
            .tint(stem.isMuted ? .red : nil)
            .help("Mute \(stem.type.title)")

            Button("S") {
                toggleSolo()
            }
            .buttonStyle(.bordered)
            .tint(stem.isSolo ? .accentColor : nil)
            .help("Solo \(stem.type.title)")

            Slider(
                value: Binding(
                    get: { stem.volume },
                    set: setVolume
                ),
                in: 0...1
            )
            .frame(width: 120)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}
