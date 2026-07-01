import SwiftUI

@main
struct StemStudioApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 980, minHeight: 660)
        }
        .defaultSize(width: 1220, height: 760)

        Settings {
            SettingsView()
                .frame(width: 520, height: 360)
        }
    }
}
