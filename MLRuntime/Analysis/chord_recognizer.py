"""Beat-synchronous chord recognition by chroma template matching.

Approach (classic DSP, no ML model):
  harmonic mix (bass + other, i.e. drums & vocals excluded)
    -> CQT-based chromagram (12 pitch classes; CQT is pitch-aligned, better than STFT)
    -> average chroma within each BEAT interval
    -> cosine-match against major / minor triad templates for all 12 roots.

Returns one chord label per beat (aligned to the `beats` list). 'N' = no chord
(silence / too little harmonic energy). The visualiser de-duplicates repeats.

Ported verbatim from the audio-sandbox webapp.
"""
import numpy as np
import librosa

NOTES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# chord qualities: major and minor triads only
QUALITIES = {
    "":  [0, 4, 7],       # major triad
    "m": [0, 3, 7],       # minor triad
}


def build_templates():
    """List of (label, unit-norm 12-vector) for every root x quality."""
    templates = []
    for root in range(12):
        for suffix, intervals in QUALITIES.items():
            v = np.zeros(12, dtype=float)
            for iv in intervals:
                v[(root + iv) % 12] = 1.0
            v /= np.linalg.norm(v)
            templates.append((NOTES[root] + suffix, v))
    return templates


def compute_chords(harm, sr, beats, hop=2048, silence_ratio=0.12):
    """Per-beat chord labels for harmonic signal `harm` given beat times `beats`."""
    beats = [float(b) for b in beats]
    templates = build_templates()

    # CQT chroma + per-frame loudness (for silence gating)
    chroma = librosa.feature.chroma_cqt(y=harm, sr=sr, hop_length=hop)   # [12, T]
    rms = librosa.feature.rms(y=harm, hop_length=hop)[0]                 # [T]
    times = librosa.frames_to_time(np.arange(chroma.shape[1]), sr=sr, hop_length=hop)

    dt = float(np.median(np.diff(beats))) if len(beats) > 1 else 0.5
    med_rms = float(np.median(rms)) + 1e-9

    labels = []
    for i, b in enumerate(beats):
        end = beats[i + 1] if i + 1 < len(beats) else b + dt
        mask = (times >= b) & (times < end)
        if mask.any():
            vec = np.median(chroma[:, mask], axis=1)
            loud = float(rms[mask].mean())
        else:                                    # beat shorter than one hop
            j = int(np.argmin(np.abs(times - b)))
            vec = chroma[:, j]
            loud = float(rms[j])

        if loud < silence_ratio * med_rms:
            labels.append("N")
            continue

        c = vec / (np.linalg.norm(vec) + 1e-9)
        best_lab, best_score = "N", -1.0
        for lab, tv in templates:
            s = float(c @ tv)
            if s > best_score:
                best_score, best_lab = s, lab
        labels.append(best_lab)

    return labels


def load_harmonic(stems_dir, sr=22050):
    """Load bass + other stems and sum them into one mono harmonic signal."""
    from pathlib import Path
    stems_dir = Path(stems_dir)
    bass, _ = librosa.load(str(stems_dir / "bass.wav"), sr=sr, mono=True)
    other, _ = librosa.load(str(stems_dir / "other.wav"), sr=sr, mono=True)
    n = min(len(bass), len(other))
    return bass[:n] + other[:n], sr


def dedupe(labels, beats):
    """Collapse consecutive identical chords -> [(t, chord), ...] change points."""
    out = []
    prev = None
    for t, lab in zip(beats, labels):
        if lab != prev and lab != "N":
            out.append((round(float(t), 3), lab))
        prev = lab
    return out
