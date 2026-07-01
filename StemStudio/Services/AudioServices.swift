import AVFAudio
import AVFoundation
import Combine
import Foundation

@MainActor
final class SingleAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) throws {
        stop()
        player = try AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopTimer()
    }

    func seek(to value: TimeInterval) {
        player?.currentTime = min(max(0, value), duration)
        currentTime = player?.currentTime ?? 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = self?.player?.currentTime ?? 0
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class StemMixerAudioController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var players: [UUID: AVAudioPlayer] = [:]
    private var timer: Timer?

    func load(stems: [StemAsset], urlResolver: (StemAsset) -> URL) {
        stop()
        players.removeAll()

        for stem in stems {
            guard let player = try? AVAudioPlayer(contentsOf: urlResolver(stem)) else { continue }
            player.prepareToPlay()
            players[stem.id] = player
            duration = max(duration, player.duration)
        }

        applyMix(stems: stems)
    }

    func applyMix(stems: [StemAsset]) {
        let hasSolo = stems.contains(where: \.isSolo)

        for stem in stems {
            let audible = !stem.isMuted && (!hasSolo || stem.isSolo)
            players[stem.id]?.volume = audible ? Float(stem.volume) : 0
        }
    }

    func toggle(stems: [StemAsset]) {
        isPlaying ? pause() : play(stems: stems)
    }

    func play(stems: [StemAsset]) {
        guard !players.isEmpty else { return }
        applyMix(stems: stems)

        let startTime = (players.values.first?.deviceCurrentTime ?? 0) + 0.08
        for player in players.values {
            player.currentTime = currentTime
            player.play(atTime: startTime)
        }

        isPlaying = true
        startTimer()
    }

    func pause() {
        currentTime = players.values.first?.currentTime ?? currentTime
        players.values.forEach { $0.pause() }
        isPlaying = false
        stopTimer()
    }

    func stop() {
        players.values.forEach {
            $0.stop()
            $0.currentTime = 0
        }
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    func seek(to value: TimeInterval, stems: [StemAsset]) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }

        currentTime = min(max(0, value), duration)
        players.values.forEach { $0.currentTime = currentTime }

        if wasPlaying { play(stems: stems) }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.players.values.first?.currentTime ?? self.currentTime
                if self.currentTime >= self.duration {
                    self.stop()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class MicrophoneMonitor: ObservableObject {
    enum PermissionState: Equatable {
        case unknown
        case authorized
        case denied
    }

    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var level: Double = 0
    @Published private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private var hasTap = false

    func requestAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted: Bool

        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            granted = false
        }

        permissionState = granted ? .authorized : .denied
        guard granted else { return }

        do {
            try startMonitoring()
        } catch {
            permissionState = .denied
        }
    }

    func stop() {
        guard isRunning || hasTap else { return }
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        level = 0
        isRunning = false
    }

    private func startMonitoring() throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            var sum: Float = 0
            for index in 0..<frameCount {
                let sample = channel[index]
                sum += sample * sample
            }

            let rms = sqrt(sum / Float(frameCount))
            let normalized = min(max(Double(rms) * 12, 0), 1)

            Task { @MainActor in
                self?.level = normalized
            }
        }

        hasTap = true
        engine.prepare()
        try engine.start()
        isRunning = true
    }
}

@MainActor
final class MockLiveRecognitionService: ObservableObject {
    @Published private(set) var detectedPitch = "—"
    @Published private(set) var confidence = 0.0
    @Published private(set) var noteIndex = 0

    private var timer: Timer?
    private var notes: [NoteEvent] = []

    func start(notes: [NoteEvent]) {
        stop()
        self.notes = notes
        noteIndex = 0

        guard !notes.isEmpty else { return }
        detectedPitch = notes[0].pitch
        confidence = 0.91

        timer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.notes.isEmpty else { return }
                self.noteIndex = (self.noteIndex + 1) % self.notes.count
                let expected = self.notes[self.noteIndex]
                let shouldMatch = self.noteIndex % 5 != 0
                self.detectedPitch = shouldMatch ? expected.pitch : ["C3", "F#2", "A2"].randomElement()!
                self.confidence = shouldMatch ? 0.88 : 0.64
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        detectedPitch = "—"
        confidence = 0
        noteIndex = 0
    }
}
