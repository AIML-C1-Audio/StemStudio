import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            if appState.selectedSection == .settings {
                SettingsCategoryList()
            } else {
                ProjectListView()
                    .navigationSplitViewColumnWidth(min: 250, ideal: 300)
            }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import Audio", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(appState.isImporting)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.mp3, .wav, .audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await appState.importAudio(from: url) }
            case .failure(let error):
                appState.alertMessage = error.localizedDescription
            }
        }
        .alert(
            "StemStudio",
            isPresented: Binding(
                get: { appState.alertMessage != nil },
                set: { if !$0 { appState.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { appState.alertMessage = nil }
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if appState.selectedSection == .settings {
            SettingsView()
        } else if let projectID = appState.selectedProjectID {
            ProjectWorkspaceView(projectID: projectID)
                .id(projectID)
        } else {
            EmptyProjectView { showImporter = true }
        }
    }
}
