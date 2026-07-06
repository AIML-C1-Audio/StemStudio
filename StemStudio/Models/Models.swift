import Foundation

// MARK: - Navigation

enum SidebarSection: String, CaseIterable, Identifiable {
    case projects = "Projects"
    case processing = "Processing"
    case completed = "Completed"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .projects: "music.note.house"
        case .processing: "waveform.badge.magnifyingglass"
        case .completed: "checkmark.circle"
        case .settings: "gearshape"
        }
    }
}

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case stems = "Stems"
    case score = "Sheet Music"
    case practice = "Practice"

    var id: String { rawValue }
}

// MARK: - Project domain

enum ProjectStage: String, Codable, CaseIterable {
    case imported
    case separating
    case separated
    case generatingScore
    case scoreReady
    case practicing
    case failed

    var title: String {
        switch self {
        case .imported: "Ready to separate"
        case .separating: "Separating instruments"
        case .separated: "Stems ready"
        case .generatingScore: "Generating sheet music"
        case .scoreReady: "Sheet music ready"
        case .practicing: "Practice in progress"
        case .failed: "Needs attention"
        }
    }
}

enum AudioFormat: String, Codable {
    case mp3
    case wav
    case other
}

struct AudioAsset: Identifiable, Codable, Hashable {
    let id: UUID
    var fileName: String
    var relativePath: String
    var duration: TimeInterval
    var format: AudioFormat
}

enum StemType: String, Codable, CaseIterable, Identifiable {
    case vocals
    case drums
    case bass
    case other

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .vocals: "music.microphone"
        case .drums: "circle.grid.cross"
        case .bass: "guitars"
        case .other: "waveform"
        }
    }
}

struct StemAsset: Identifiable, Codable, Hashable {
    let id: UUID
    var type: StemType
    var relativePath: String
    var duration: TimeInterval
    var volume: Double = 0.85
    var isMuted: Bool = false
    var isSolo: Bool = false
}

struct NoteEvent: Identifiable, Codable, Hashable {
    let id: UUID
    var pitch: String
    var midi: Int
    var startTime: TimeInterval
    var duration: TimeInterval
    var confidence: Double
}

// A single beat within a measure of a real (transcribed) score.
struct ScoreBeat: Identifiable, Codable, Hashable {
    let id: UUID
    var time: TimeInterval
    var position: Int          // 1...beatsPerBar (1 = downbeat / bar start)
    var chord: String          // e.g. "F#m"; "N" = no chord
    var triad: [NoteEvent]     // the chord spelled as triad notes
    var lyric: String          // lyric words falling on this beat ("" if none)
}

// One measure (bar) of a real score, delimited by madmom-DBN downbeats.
struct ScoreMeasure: Identifiable, Codable, Hashable {
    let id: UUID
    var number: Int
    var timeSignature: String  // e.g. "4/4"
    var start: TimeInterval
    var end: TimeInterval
    var beats: [ScoreBeat]
    var lyric: String          // concatenated lyric line for the measure
}

struct ScoreAsset: Identifiable, Codable, Hashable {
    let id: UUID
    var stemID: UUID
    var instrument: StemType
    var createdAt: Date
    var notes: [NoteEvent]

    // Populated only for real (vocal) scores; nil for dummy/mock scores so
    // previously-saved projects keep decoding.
    var measures: [ScoreMeasure]? = nil
    var beatsPerBar: Int? = nil
    var bpm: Double? = nil
    var lyricsLanguage: String? = nil
    var key: String? = nil          // detected major key, e.g. "A" (for the staff key signature)

    var isRealScore: Bool { !(measures?.isEmpty ?? true) }
}

struct PracticeSession: Identifiable, Codable, Hashable {
    let id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var totalExpectedNotes: Int
    var correctNotes: Int
    var missedNotes: Int

    var accuracy: Double {
        guard totalExpectedNotes > 0 else { return 0 }
        return Double(correctNotes) / Double(totalExpectedNotes)
    }
}

struct SongProject: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var originalAudio: AudioAsset
    var stems: [StemAsset]
    var scores: [ScoreAsset]
    var practiceSessions: [PracticeSession]
    var stage: ProjectStage

    var latestScore: ScoreAsset? {
        scores.sorted(by: { $0.createdAt > $1.createdAt }).first
    }
}

struct ProcessingStatus: Equatable {
    var progress: Double
    var message: String
}
