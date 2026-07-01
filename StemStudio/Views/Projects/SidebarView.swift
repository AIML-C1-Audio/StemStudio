import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List(SidebarSection.allCases, selection: $appState.selectedSection) { section in
            Label(section.rawValue, systemImage: section.systemImage)
                .tag(section)
        }
        .navigationTitle("StemStudio")
        .listStyle(.sidebar)
    }
}

struct SettingsCategoryList: View {
    var body: some View {
        List {
            Label("General", systemImage: "gear")
            Label("Audio", systemImage: "speaker.wave.2")
            Label("Processing", systemImage: "cpu")
            Label("Practice", systemImage: "music.mic")
        }
        .navigationTitle("Settings")
    }
}
