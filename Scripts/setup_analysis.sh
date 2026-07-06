#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

RUNTIME_DIR="$ROOT_DIR/MLRuntime/Analysis"
LOCAL_DIR="$ROOT_DIR/.local/analysis"
VENV_DIR="$LOCAL_DIR/venv"

# Model imports
MODELS_DIR="$LOCAL_DIR/models"
WHISPER_DIR="$MODELS_DIR/whisper"
WHISPER_MODEL="medium"

RUNNER_FILE="$RUNTIME_DIR/score_runner.py"

# ----------------------------------------------------------------------------
# Locate a Python 3.10 interpreter.
#
# Prefer the machine's default `python3` (exactly like setup_demucs.sh) — no
# pyenv dependency. The analysis recipe (madmom 0.16.1 / natten 0.17.5 / numpy
# 1.23.5) is pinned to Python 3.10, so if the default isn't 3.10 we fall back to
# any python3.10 on PATH (Homebrew's python@3.10, pyenv, etc.), and ANALYSIS_PYTHON
# overrides everything.
# ----------------------------------------------------------------------------

is_py310() {
    [[ -x "$1" ]] && \
    [[ "$("$1" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" == "3.10" ]]
}

PYBIN=""
for cand in \
    "${ANALYSIS_PYTHON:-}" \
    "$(command -v python3 || true)" \
    "$(command -v python3.10 || true)" \
    "$HOME/.pyenv/versions/3.10.11/bin/python"
do
    [[ -n "$cand" ]] || continue
    if is_py310 "$cand"; then PYBIN="$cand"; break; fi
done

if [[ -z "$PYBIN" ]]; then
    echo "ERROR: butuh Python 3.10 (recipe madmom/natten/numpy dipin ke 3.10)."
    echo "Default python3: $(command -v python3 >/dev/null 2>&1 && python3 --version 2>&1 || echo 'tidak ada')."
    echo "Sediakan Python 3.10, misalnya:"
    echo "  brew install python@3.10        (lalu ada di /opt/homebrew/bin/python3.10)"
    echo "  pyenv install 3.10.11"
    echo "atau set ANALYSIS_PYTHON=/path/to/python3.10 lalu jalankan ulang."
    exit 1
fi

PY_VERSION="3.10"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "ERROR: Xcode Command Line Tools tidak ditemukan (dibutuhkan untuk"
    echo "mengcompile natten/madmom). Instal dengan:  xcode-select --install"
    exit 1
fi

# ----------------------------------------------------------------------------
# Fast path: already built and importable?
# ----------------------------------------------------------------------------

if [[ -x "$VENV_DIR/bin/python" ]] && \
   "$VENV_DIR/bin/python" -c "import allin1fix, madmom, natten, torch, whisper, librosa" >/dev/null 2>&1; then
    echo "Analysis runtime sudah tersedia dan valid: $VENV_DIR"
    echo "Hapus folder tersebut lalu jalankan ulang untuk membangun ulang."
    exit 0
fi

echo "Membangun analysis runtime di: $VENV_DIR"
echo "Interpreter dasar: $PYBIN ($PY_VERSION)"

mkdir -p "$LOCAL_DIR"
rm -rf "$VENV_DIR"
"$PYBIN" -m venv "$VENV_DIR"

PY="$VENV_DIR/bin/python"

# ----------------------------------------------------------------------------
# Build (mirrors audio-sandbox setup_env.sh).
# ----------------------------------------------------------------------------

"$PY" -m pip install -U pip "setuptools<81" wheel Cython cmake ninja
"$PY" -m pip install "numpy==1.23.5" scipy soundfile
"$PY" -m pip install "torch==2.7.1" "torchaudio==2.7.1"

export CXXFLAGS="-Wno-invalid-specialization -Wno-error=invalid-specialization"
export CFLAGS="$CXXFLAGS"

echo "Mengcompile natten==0.17.5 dari source (butuh beberapa menit)..."
PATH="$VENV_DIR/bin:$PATH" "$PY" -m pip install --no-build-isolation --no-cache-dir "natten==0.17.5"

echo "Mengcompile madmom==0.16.1 dari source..."
"$PY" -m pip install --no-build-isolation "madmom==0.16.1"

CONSTRAINTS="$(mktemp)"
printf 'numpy==1.23.5\nsetuptools<81\ntorch==2.7.1\ntorchaudio==2.7.1\nnatten==0.17.5\n' > "$CONSTRAINTS"
"$PY" -m pip install -c "$CONSTRAINTS" all-in-one-fix
rm -f "$CONSTRAINTS"

echo "Menginstal openai-whisper..."
"$PY" -m pip install -c <(printf 'numpy==1.23.5\ntorch==2.7.1\ntorchaudio==2.7.1\n') openai-whisper

# ----------------------------------------------------------------------------
# PATCHES to installed files (idempotent).
# ----------------------------------------------------------------------------

VENV_DIR="$VENV_DIR" "$PY" - <<'PYEOF'
import os, pathlib
sp = pathlib.Path(os.environ["VENV_DIR"]) / "lib" / "python3.10" / "site-packages"

# 1) madmom: collections ABC import moved in Python 3.10.
p = sp / "madmom" / "processors.py"
t = p.read_text()
p.write_text(t.replace("from collections import MutableSequence",
                       "from collections.abc import MutableSequence"))

# 2) natten: guard CUDA-only device query so import works on CPU/MPS Macs.
m = sp / "natten" / "utils" / "misc.py"
t = m.read_text()
if "if not torch.cuda.is_available():" not in t:
    t = t.replace(
        "def get_device_cc(device_index: Optional[_device_t] = None) -> int:\n"
        "    major, minor = torch.cuda.get_device_capability(device_index)",
        "def get_device_cc(device_index: Optional[_device_t] = None) -> int:\n"
        "    if not torch.cuda.is_available():\n"
        "        return 0  # CPU/MPS build (e.g. macOS): no CUDA compute capability\n"
        "    major, minor = torch.cuda.get_device_capability(device_index)")
    m.write_text(t)
print("patches applied")
PYEOF

# ----------------------------------------------------------------------------
# Validate.
# ----------------------------------------------------------------------------

"$PY" -c "import allin1fix, madmom, natten, torch, whisper, librosa; print('OK | torch', torch.__version__, '| natten', natten.__version__)"

# ----------------------------------------------------------------------------
# Bundle the Whisper
# ----------------------------------------------------------------------------

mkdir -p "$WHISPER_DIR"

# --- Whisper medium ---
SRC_WHISPER="$HOME/.cache/whisper/$WHISPER_MODEL.pt"
if [[ ! -f "$WHISPER_DIR/$WHISPER_MODEL.pt" ]]; then
    if [[ -f "$SRC_WHISPER" ]]; then
        echo "Menyalin Whisper $WHISPER_MODEL.pt (~1.4 GB) dari ~/.cache..."
        cp "$SRC_WHISPER" "$WHISPER_DIR/"
    else
        echo "Mengunduh Whisper $WHISPER_MODEL (~1.4 GB, sekali saja)..."
        WHISPER_DIR="$WHISPER_DIR" WHISPER_MODEL="$WHISPER_MODEL" "$PY" - <<'PYEOF'
import os, whisper
whisper.load_model(os.environ['WHISPER_MODEL'], download_root=os.environ['WHISPER_DIR'])
print('whisper weights downloaded')
PYEOF
    fi
fi

echo ""
echo "Setup selesai."
echo "Python:  $PY"
echo "Runner:  $RUNNER_FILE"
echo "Models:  $MODELS_DIR"
