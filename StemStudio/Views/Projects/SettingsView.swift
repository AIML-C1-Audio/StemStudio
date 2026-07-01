import SwiftUI

struct SettingsView: View {
    @AppStorage("keepIntermediateFiles") private var keepIntermediateFiles = true
    @AppStorage("countInSeconds") private var countInSeconds = 3
    @AppStorage("confidenceThreshold") private var confidenceThreshold = 0.70

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Project storage", value: "Application Support/StemStudio")
                Toggle("Keep intermediate files", isOn: $keepIntermediateFiles)
            }

            Section("Practice") {
                Stepper("Count-in: \(countInSeconds) seconds", value: $countInSeconds, in: 0...8)
                Slider(value: $confidenceThreshold, in: 0.4...0.95) {
                    Text("Confidence threshold")
                }
                LabeledContent("Threshold", value: confidenceThreshold.formatted(.percent.precision(.fractionLength(0))))
            }

            Section("Processing") {
                LabeledContent("Separation service", value: "Mock Demucs Adapter")
                LabeledContent("Score service", value: "Mock Transcription Adapter")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .padding()
    }
}
