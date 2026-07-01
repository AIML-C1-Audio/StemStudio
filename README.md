# StemStudio

Starter project **macOS SwiftUI** untuk workflow aplikasi musik berbasis AI/ML:

1. Import lagu MP3/WAV.
2. Pisahkan lagu menjadi `vocals`, `drums`, `bass`, dan `other`.
3. Pilih stem dan generate sheet music/timed notes.
4. Jalankan practice mode dengan input mikrofon dan highlight note.

Project ini menggunakan **mock ML services** agar UI dapat dijalankan end-to-end sebelum model dari tiap anggota tim selesai.

## Persyaratan

- macOS 14 atau lebih baru
- Xcode 15 atau lebih baru
- Swift 5

## Menjalankan project

1. Ekstrak ZIP.
2. Buka `StemStudio.xcodeproj` menggunakan Xcode.
3. Pilih scheme **StemStudio** dan destination **My Mac**.
4. Pada target **StemStudio → Signing & Capabilities**, pilih development team Anda bila Xcode memintanya.
5. Tekan `⌘R`.
6. Klik **Import Audio** dan pilih file MP3 atau WAV.

Project menyertakan `NSMicrophoneUsageDescription` dan entitlement audio input. macOS akan meminta izin mikrofon saat Practice Mode pertama kali dibuka.

## Fitur yang sudah diimplementasikan

- `NavigationSplitView` tiga kolom untuk aplikasi desktop.
- Project library: all projects, processing, completed, settings.
- Import MP3/WAV melalui system file importer.
- Security-scoped file access dan penyalinan file ke Application Support.
- Persistence metadata project menggunakan JSON.
- Preview audio asli dengan play, pause, seek, dan duration.
- Mock Demucs processing dengan progress update.
- Stem mixer sinkron dengan mute, solo, volume, play/pause, dan seek.
- Mock score generation dengan timed `NoteEvent`.
- Sheet music viewer sederhana dan zoom.
- Microphone permission, live input level meter, dan mock note recognition.
- Practice summary.
- Error alert dan status per tahap.

## Struktur utama

```text
StemStudio/
├── App/
│   ├── StemStudioApp.swift
│   ├── AppState.swift
│   └── RootView.swift
├── Models/
│   └── Models.swift
├── Services/
│   ├── ProjectRepository.swift
│   ├── MLServices.swift
│   └── AudioServices.swift
├── Views/
│   ├── Components/
│   ├── Projects/
│   ├── Separation/
│   ├── Stems/
│   ├── Score/
│   └── Practice/
└── Resources/
    ├── Info.plist
    └── StemStudio.entitlements
```

## Mengganti mock Demucs

Kontraknya berada di `Services/MLServices.swift`:

```swift
protocol StemSeparationService {
    func separate(
        sourceURL: URL,
        destinationDirectory: URL,
        duration: TimeInterval,
        progress: @escaping (Double, String) -> Void
    ) async throws -> [StemAsset]
}
```

Buat implementasi baru, misalnya:

```swift
struct FastAPIDemucsService: StemSeparationService {
    // Upload/call backend, poll progress, download empat stem,
    // lalu kembalikan [StemAsset].
}
```

Kemudian ganti dependency di initializer `AppState`:

```swift
separationService: any StemSeparationService = FastAPIDemucsService()
```

Output yang diharapkan:

```text
stems/
├── vocals.wav
├── drums.wav
├── bass.wav
└── other.wav
```

## Mengganti mock sheet music

Implementasikan `ScoreGenerationService` dan kembalikan `ScoreAsset` yang berisi note timeline. Setiap note memiliki ID stabil agar UI dapat melakukan highlight:

```swift
struct NoteEvent {
    let id: UUID
    var pitch: String
    var midi: Int
    var startTime: TimeInterval
    var duration: TimeInterval
    var confidence: Double
}
```

Untuk produk sebenarnya, model dapat menghasilkan MusicXML/MIDI untuk rendering dan JSON/timed notes untuk interaksi UI.

## Mengganti mock live recognition

`MockLiveRecognitionService` berada di `Services/AudioServices.swift`. `MicrophoneMonitor` sudah menyediakan akses input dan level meter. Adapter model ketiga nantinya perlu menerima buffer PCM dari tap `AVAudioEngine`, lalu menerbitkan event note/chord terdeteksi.

## Penyimpanan project

Metadata dan file disimpan di:

```text
~/Library/Application Support/StemStudio/Projects/
```

Mock separation menduplikasi lagu sumber ke empat file agar playback mixer dapat diuji. Mock ini **tidak benar-benar memisahkan audio**.

## Catatan validasi

Semua file Swift telah lolos pemeriksaan parser Swift pada environment pembuatan artifact. Build macOS penuh tetap perlu dijalankan di Xcode karena environment ini tidak menyediakan SDK SwiftUI/AppKit macOS.
