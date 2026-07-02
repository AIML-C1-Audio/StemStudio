#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PYTHON="$ROOT_DIR/.local/demucs/venv/bin/python"
RUNNER="$ROOT_DIR/MLRuntime/Demucs/demucs_runner.py"
TORCH_CACHE="$ROOT_DIR/.local/demucs/torch-cache"

INPUT_FILE="${1:-}"

if [[ -z "$INPUT_FILE" ]]; then
    echo "Usage:"
    echo "  ./Scripts/test_demucs.sh /path/to/song.mp3"
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Input tidak ditemukan:"
    echo "$INPUT_FILE"
    exit 1
fi

if [[ ! -x "$PYTHON" ]]; then
    echo "Runtime belum tersedia."
    echo "Jalankan ./Scripts/setup_demucs.sh terlebih dahulu."
    exit 1
fi

FILE_NAME="$(basename "$INPUT_FILE")"
TRACK_NAME="${FILE_NAME%.*}"

OUTPUT_DIR="$ROOT_DIR/.local/test-outputs/$TRACK_NAME"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

export TORCH_HOME="$TORCH_CACHE"

"$PYTHON" "$RUNNER" \
    --input "$INPUT_FILE" \
    --output "$OUTPUT_DIR" \
    --device cpu

for STEM in vocals drums bass other; do
    STEM_FILE="$OUTPUT_DIR/$STEM.wav"

    if [[ ! -f "$STEM_FILE" ]]; then
        echo "ERROR: output tidak ditemukan: $STEM_FILE"
        exit 1
    fi
done

echo ""
echo "Separation berhasil."
echo "Output:"
echo "$OUTPUT_DIR"
