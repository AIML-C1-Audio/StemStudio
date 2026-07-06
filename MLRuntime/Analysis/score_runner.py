from __future__ import annotations

"""
StemStudio vocal sheet-music runner.

Given the four already-separated stems (produced by StemStudio's Demucs step),
this produces a real, measure-based lead sheet for the vocal track:

  * madmom-DBN beats / downbeats via all-in-one-fix (source separation SKIPPED —
    the stems are fed in directly through allin1fix's stems_input mode);
  * one triad chord per beat via chroma template matching on bass + other;
  * lyrics (word-level timestamps) via Whisper on the vocal stem;
  * beats grouped into measures at each downbeat (time signature = beats per bar).

Protocol (identical in spirit to demucs_runner.py): one JSON object per line on
stdout — {"type": "status"|"progress"|"completed"|"error", ...}. Swift reads
each line through a Pipe + JSONDecoder. The full score is also written to
--output as a JSON file.

Model weights are loaded from the bundle at .local/analysis/models (populated by
Scripts/setup_analysis.sh) so the app never touches ~/.cache.
"""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


# ============================================================
# Paths / bundled model weights
# ============================================================

RUNNER_DIR = Path(__file__).resolve().parent          # MLRuntime/Analysis
ROOT_DIR = RUNNER_DIR.parent.parent                   # repository root
DEFAULT_MODELS_DIR = ROOT_DIR / ".local" / "analysis" / "models"

LOCAL_BEAT_WEIGHTS = RUNNER_DIR / "models" / "allin1-finetuned.pth"

ALLIN1_ARCH_NAME = "harmonix-fold0"

def use_local_beat_weights() -> None:
    """Make all-in-one load its checkpoint from the committed local file.

    all-in-one's loader fetches the weight via huggingface_hub.hf_hub_download;
    we intercept that one call and return the bundled path, so analysis never
    touches the network or the HF cache layout (blobs/refs/snapshots).
    """
    import allin1fix.models.loaders as loaders
    original = loaders.hf_hub_download

    def patched(repo_id=None, filename=None, *args, **kwargs):
        if repo_id == "taejunkim/allinone" and LOCAL_BEAT_WEIGHTS.exists():
            return str(LOCAL_BEAT_WEIGHTS)
        return original(repo_id=repo_id, filename=filename, *args, **kwargs)

    loaders.hf_hub_download = patched


def configure_model_bundle(models_dir: Path) -> Path:
    """Point the Hugging Face + Whisper loaders at the in-project weight bundle.

    Must run before allin1fix / whisper import-time or download-time lookups.
    Returns the Whisper download_root to pass through explicitly.
    """
    hf_cache = models_dir / "hf" / "hub"
    whisper_dir = models_dir / "whisper"

    if hf_cache.exists():
        os.environ["HF_HUB_CACHE"] = str(hf_cache)
        os.environ["HF_HOME"] = str(models_dir / "hf")
        # Weights are pre-bundled; never hit the network for them.
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

    return whisper_dir


# ============================================================
# JSON output (one object per line)
# ============================================================

def emit(payload: Dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def status(stage: str, message: str) -> None:
    emit({"type": "status", "stage": stage, "message": message})


def progress(value: float, message: str) -> None:
    emit({"type": "progress",
          "progress": round(min(max(value, 0.0), 1.0), 4),
          "message": message})


# ============================================================
# Chord -> triad note spelling
# ============================================================

_PITCH_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
_NAME_TO_PC = {n: i for i, n in enumerate(_PITCH_NAMES)}

# Root voiced in the octave starting at C4 (MIDI 60) so triads sit in a readable
# treble range regardless of the detected root.
_ROOT_BASE_MIDI = 60


def parse_chord(label: str):
    """'C' -> (0, 'maj'); 'F#m' -> (6, 'min'); returns None for 'N'/unknown."""
    if not label or label == "N":
        return None
    quality = "maj"
    root = label
    if label.endswith("m") and not label.endswith("dim"):
        quality = "min"
        root = label[:-1]
    pc = _NAME_TO_PC.get(root)
    if pc is None:
        return None
    return pc, quality


_MAJOR_KEY_NAMES = {0: "C", 1: "Db", 2: "D", 3: "Eb", 4: "E", 5: "F",
                    6: "F#", 7: "G", 8: "Ab", 9: "A", 10: "Bb", 11: "B"}


def detect_key(chords: List[str]) -> str:
    """Best-fit major key from the chord sequence (for the staff key signature)."""
    from collections import Counter
    weights: Counter = Counter()
    for c in chords:
        parsed = parse_chord(c)
        if parsed is not None:
            weights[parsed] += 1        # (root_pc, quality)
    if not weights:
        return "C"

    scale = [0, 2, 4, 5, 7, 9, 11]
    quals = ["maj", "min", "min", "maj", "maj", "min", "dim"]
    best_key, best_score = 0, -1.0
    for key in range(12):
        diatonic = {(key + iv) % 12: quals[deg] for deg, iv in enumerate(scale)}
        score = 0.0
        for (pc, quality), w in weights.items():
            if diatonic.get(pc) == quality:
                score += w
            elif pc in diatonic:
                score += w * 0.3        # right root, wrong quality — still in key
        if score > best_score:
            best_score, best_key = score, key
    return _MAJOR_KEY_NAMES[best_key]


def chord_to_triad(label: str) -> List[Dict[str, Any]]:
    """Return the triad notes for a chord label as [{name, midi}], root-position."""
    parsed = parse_chord(label)
    if parsed is None:
        return []
    pc, quality = parsed
    intervals = [0, 4, 7] if quality == "maj" else [0, 3, 7]
    root_midi = _ROOT_BASE_MIDI + pc
    notes = []
    for iv in intervals:
        midi = root_midi + iv
        name = _PITCH_NAMES[midi % 12] + str(midi // 12 - 1)   # MIDI 60 -> C4
        notes.append({"name": name, "midi": midi})
    return notes


# ============================================================
# Measure assembly
# ============================================================

def build_measures(
    beats: List[float],
    beat_positions: List[int],
    chords: List[str],
    lyrics: Dict[str, Any],
    duration: float,
) -> Dict[str, Any]:
    """Group beats into measures at each downbeat and attach chords + lyrics."""
    beats_per_bar = max(beat_positions) if beat_positions else 4

    # Flatten Whisper words to (start, text) for beat-window assignment.
    words = []
    for seg in lyrics.get("segments", []):
        for w in seg.get("words", []):
            words.append((float(w["start"]), w["word"].strip()))
    words.sort(key=lambda x: x[0])

    def lyric_for(beat_start: float, beat_end: float) -> str:
        return " ".join(t for (s, t) in words if beat_start <= s < beat_end and t)

    # Build per-beat records, keeping the original beat index for measure spans.
    beat_records = []
    for i, t in enumerate(beats):
        end = beats[i + 1] if i + 1 < len(beats) else duration
        pos = beat_positions[i] if i < len(beat_positions) else ((i % beats_per_bar) + 1)
        chord = chords[i] if i < len(chords) else "N"
        beat_records.append({
            "index": i,
            "time": round(float(t), 3),
            "position": int(pos),
            "chord": chord,
            "triad": chord_to_triad(chord),
            "lyric": lyric_for(float(t), float(end)),
        })

    # Split into measures at every position == 1 (downbeat). Any beats before the
    # first downbeat form a leading pickup measure.
    groups: List[List[Dict[str, Any]]] = []
    current: List[Dict[str, Any]] = []
    for rec in beat_records:
        if rec["position"] == 1 and current:
            groups.append(current)
            current = []
        current.append(rec)
    if current:
        groups.append(current)

    out_measures = []
    for idx, group in enumerate(groups):
        start = group[0]["time"]
        last_index = group[-1]["index"]
        end = beats[last_index + 1] if last_index + 1 < len(beats) else duration
        for rec in group:
            rec.pop("index", None)
        out_measures.append({
            "number": idx + 1,
            "time_signature": f"{beats_per_bar}/4",
            "start": round(float(start), 3),
            "end": round(float(end), 3),
            "beats": group,
            "lyric": " ".join(b["lyric"] for b in group if b["lyric"]).strip(),
        })

    return {"beats_per_bar": beats_per_bar, "measures": out_measures}


# ============================================================
# Main analysis
# ============================================================

def analyze_vocals(stems_dir: Path, device: str, whisper_dir: Path,
                   whisper_model: str) -> Dict[str, Any]:
    import numpy as np
    import librosa

    stem_paths = {s: stems_dir / f"{s}.wav" for s in ("bass", "drums", "other", "vocals")}
    for name, p in stem_paths.items():
        if not p.is_file():
            raise FileNotFoundError(f"Missing {name} stem: {p}")

    # --- beats / downbeats via all-in-one-fix, feeding stems directly ---
    status("analyzingBeats", "Detecting beats and downbeats (madmom DBN)")
    progress(0.05, "Loading beat/downbeat model")

    import allin1fix as allin1
    from allin1fix.stems_input import StemsInput

    if not LOCAL_BEAT_WEIGHTS.exists():
        raise FileNotFoundError(
            f"Beat/downbeat weight not found: {LOCAL_BEAT_WEIGHTS}. "
            f"It should be committed with the repo."
        )
    use_local_beat_weights()

    stems_input = StemsInput(
        bass=stem_paths["bass"],
        drums=stem_paths["drums"],
        other=stem_paths["other"],
        vocals=stem_paths["vocals"],
        identifier=stems_dir.name or "stemstudio",
    )

    cache_dir = stems_dir.parent / "analysis_cache"
    r = allin1.analyze(
        stems_input=stems_input,
        model=ALLIN1_ARCH_NAME,   # committed weight is intercepted for this name
        device=device,
        include_activations=False,
        demix_dir=str(cache_dir / "demix"),
        spec_dir=str(cache_dir / "spec"),
        keep_byproducts=False,
        overwrite=True,
        multiprocess=False,
    )

    beats = [round(float(x), 4) for x in r.beats]
    downbeats = [round(float(x), 4) for x in r.downbeats]
    beat_positions = [int(x) for x in r.beat_positions]
    bpm = int(r.bpm)
    progress(0.45, f"{len(beats)} beats · {len(downbeats)} downbeats · {bpm} BPM")

    # --- duration from the vocal stem ---
    y, sr = librosa.load(str(stem_paths["vocals"]), sr=22050, mono=True)
    duration = round(len(y) / sr, 3)

    # --- beat-synchronous chords (bass + other) ---
    status("recognizingChords", "Recognising chords per beat")
    import chord_recognizer
    harm, hsr = chord_recognizer.load_harmonic(stems_dir, sr=22050)
    chords = chord_recognizer.compute_chords(harm, hsr, beats)
    progress(0.60, f"{len(chord_recognizer.dedupe(chords, beats))} chord changes")

    # --- lyrics via Whisper on the vocal stem ---
    status("transcribingLyrics", "Transcribing lyrics (Whisper)")
    import lyrics as lyr
    lyrics_data = lyr.transcribe(
        stem_paths["vocals"], model_name=whisper_model,
        download_root=str(whisper_dir) if whisper_dir else None,
    )
    progress(0.90, f"{len(lyrics_data.get('segments', []))} lyric lines "
                   f"({lyrics_data.get('language')})")

    # --- assemble measures ---
    status("buildingScore", "Building measure-based score")
    measure_data = build_measures(beats, beat_positions, chords, lyrics_data, duration)

    return {
        "instrument": "vocals",
        "song_duration": duration,
        "bpm": bpm,
        "beats_per_bar": measure_data["beats_per_bar"],
        "key": detect_key(chords),
        "language": lyrics_data.get("language"),
        "beats": beats,
        "downbeats": downbeats,
        "measures": measure_data["measures"],
    }


# ============================================================
# CLI
# ============================================================

def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="StemStudio vocal sheet-music runner.")
    parser.add_argument("--stems-dir", required=True,
                        help="Directory containing bass/drums/other/vocals.wav.")
    parser.add_argument("--output", required=True,
                        help="Path to write the score JSON.")
    parser.add_argument("--instrument", default="vocals",
                        help="Instrument stem to transcribe (only 'vocals' is real).")
    parser.add_argument("--device", choices=["auto", "cpu", "cuda"], default="cpu")
    parser.add_argument("--models-dir", default=str(DEFAULT_MODELS_DIR),
                        help="Bundled model weights directory.")
    parser.add_argument("--whisper-model", default="medium")
    # Accepted for CLI/caller compatibility but not used to pick the architecture:
    # the committed single-fold weight is always loaded (see ALLIN1_ARCH_NAME).
    parser.add_argument("--beat-model", default="allin1-finetuned")
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()

    if args.instrument != "vocals":
        emit({"type": "error", "errorType": "Unsupported",
              "message": f"Real sheet music is only available for the vocals stem "
                         f"(got '{args.instrument}')."})
        return 1

    device = "cpu" if args.device == "auto" else args.device
    whisper_dir = configure_model_bundle(Path(args.models_dir))

    status("loadingRuntime", "Preparing analysis runtime")

    try:
        score = analyze_vocals(
            stems_dir=Path(args.stems_dir).expanduser().resolve(),
            device=device,
            whisper_dir=whisper_dir,
            whisper_model=args.whisper_model,
        )

        output_path = Path(args.output).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(score, ensure_ascii=False))

        emit({
            "type": "completed",
            "progress": 1.0,
            "output": str(output_path),
            "measures": len(score["measures"]),
            "bpm": score["bpm"],
            "beatsPerBar": score["beats_per_bar"],
            "language": score["language"],
        })
        return 0

    except KeyboardInterrupt:
        emit({"type": "cancelled", "message": "Sheet music generation cancelled."})
        return 130
    except Exception as error:  # noqa: BLE001 — report everything to Swift
        emit({"type": "error", "errorType": type(error).__name__, "message": str(error)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
