"""Lyric transcription with OpenAI Whisper, on the separated vocal stem.

Language is auto-detected (no language forced), so any language works.
Returns segment- and word-level timestamps for karaoke-style rendering.

Adapted from the audio-sandbox webapp: `download_root` lets StemStudio load the
weights bundled under .local/analysis/models/whisper instead of ~/.cache.
"""
from pathlib import Path

_MODEL = None


def get_model(name="medium", download_root=None):
    global _MODEL
    if _MODEL is None:
        import whisper
        _MODEL = whisper.load_model(name, download_root=download_root)
    return _MODEL


def transcribe(vocals_path, model_name="medium", download_root=None):
    """Transcribe the vocal stem. Returns {language, segments:[{start,end,text,words}]}."""
    model = get_model(model_name, download_root=download_root)
    result = model.transcribe(
        str(vocals_path),
        language=None,            # auto-detect (all languages)
        word_timestamps=True,
        verbose=False,
    )
    segments = []
    for seg in result.get("segments", []):
        words = [
            {"start": round(float(w["start"]), 3),
             "end": round(float(w["end"]), 3),
             "word": w["word"]}
            for w in seg.get("words", [])
            if w.get("start") is not None and w.get("end") is not None
        ]
        text = seg.get("text", "").strip()
        if not text:
            continue
        segments.append({
            "start": round(float(seg["start"]), 3),
            "end": round(float(seg["end"]), 3),
            "text": text,
            "words": words,
        })
    return {"language": result.get("language"), "segments": segments}
