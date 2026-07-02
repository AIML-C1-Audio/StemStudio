#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

RUNTIME_DIR="$ROOT_DIR/MLRuntime/Demucs"
LOCAL_DIR="$ROOT_DIR/.local/demucs"
VENV_DIR="$LOCAL_DIR/venv"
TORCH_CACHE_DIR="$LOCAL_DIR/torch-cache"

REQUIREMENTS_FILE="$RUNTIME_DIR/requirements.txt"
RUNNER_FILE="$RUNTIME_DIR/demucs_runner.py"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg tidak ditemukan."
    echo "Instal dengan:"
    echo "  brew install ffmpeg"
    exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
    echo "ERROR: ffprobe tidak ditemukan."
    echo "Instal dengan:"
    echo "  brew install ffmpeg"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 tidak ditemukan."
    exit 1
fi

mkdir -p "$LOCAL_DIR"
mkdir -p "$TORCH_CACHE_DIR"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "Membuat virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

PYTHON="$VENV_DIR/bin/python"

echo "Menginstal dependency Demucs..."

"$PYTHON" -m pip install --upgrade pip setuptools wheel
"$PYTHON" -m pip install -r "$REQUIREMENTS_FILE"

export TORCH_HOME="$TORCH_CACHE_DIR"

echo "Mengunduh dan memvalidasi htdemucs_ft..."

"$PYTHON" - <<'PY'
from demucs.pretrained import get_model

model = get_model("htdemucs_ft")

expected = {"vocals", "drums", "bass", "other"}
actual = set(model.sources)

if actual != expected:
    raise RuntimeError(
        f"Unexpected model sources: {sorted(actual)}"
    )

print("Model: htdemucs_ft")
print("Sources:", ", ".join(model.sources))
print("Sample rate:", model.samplerate)
print("Channels:", model.audio_channels)
PY

echo ""
echo "Setup selesai."
echo "Python: $PYTHON"
echo "Runner: $RUNNER_FILE"
echo "Torch cache: $TORCH_CACHE_DIR"
