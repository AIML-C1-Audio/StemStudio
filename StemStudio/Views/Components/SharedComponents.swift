import SwiftUI

struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

struct StatusBadge: View {
    let stage: ProjectStage

    var body: some View {
        Label(stage.title, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
    }

    private var icon: String {
        switch stage {
        case .imported: "tray.and.arrow.down"
        case .separating, .generatingScore: "hourglass"
        case .separated: "waveform.path.ecg"
        case .scoreReady: "music.note.list"
        case .practicing: "music.mic"
        case .failed: "exclamationmark.triangle"
        }
    }
}

struct TimeLabel: View {
    let value: TimeInterval

    var body: some View {
        Text(value.stemStudioTime)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.primary)
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

struct WaveformPlaceholder: View {
    let seed: Int

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let midY = proxy.size.height / 2
                let samples = 90
                let width = proxy.size.width / CGFloat(samples - 1)

                for index in 0..<samples {
                    let x = CGFloat(index) * width
                    let value = abs(sin(Double(index + seed) * 0.41) * cos(Double(index) * 0.13))
                    let amplitude = CGFloat(value) * proxy.size.height * 0.42
                    path.move(to: CGPoint(x: x, y: midY - amplitude))
                    path.addLine(to: CGPoint(x: x, y: midY + amplitude))
                }
            }
            .stroke(.secondary, lineWidth: 1)
        }
        .frame(height: 76)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension TimeInterval {
    var stemStudioTime: String {
        guard isFinite && !isNaN else { return "00:00" }
        let total = max(0, Int(self.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
