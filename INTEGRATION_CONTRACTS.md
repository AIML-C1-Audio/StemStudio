# Integration Contracts

## 1. Stem separation

### Input

- Local MP3/WAV URL
- Destination directory
- Progress callback: `0.0 ... 1.0`, human-readable stage

### Output

Exactly one audio file per stem type:

- vocals
- drums
- bass
- other

All outputs should have matching duration, sample rate, channel count, and timeline alignment.

## 2. Score generation

### Input

- One `StemAsset`
- Instrument/stem type

### Required interactive output

- Stable note ID
- Pitch name
- MIDI note
- Start timestamp
- Duration
- Confidence

### Optional display/export output

- MusicXML
- MIDI
- PDF

## 3. Live recognition

### Input

- PCM buffers from `AVAudioEngine.inputNode`
- Sample rate and channel metadata

### Output event

```json
{
  "timestamp": 14.25,
  "note": "E2",
  "midi": 40,
  "chord": null,
  "confidence": 0.91
}
```

Events should be delivered on a serial stream and converted to main-actor state before updating SwiftUI.
