from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any, Dict

import soundfile as sf


# ============================================================
# Fixed StemStudio inference configuration
# ============================================================

MODEL_NAME = "htdemucs_ft"

EXPECTED_STEMS = {
    "vocals",
    "drums",
    "bass",
    "other",
}

SHIFTS = 1
OVERLAP = 0.25
SEGMENT = None
NUM_WORKERS = 0


# ============================================================
# JSON output
# ============================================================

def emit(payload: Dict[str, Any]) -> None:
    """
    Mengirim satu JSON object per baris ke stdout.

    Swift membaca setiap baris ini melalui Pipe dan
    JSONDecoder.
    """
    print(
        json.dumps(payload, ensure_ascii=False),
        flush=True,
    )


# ============================================================
# Device selection
# ============================================================

def resolve_device(requested_device: str) -> str:
    """
    Memilih device inference.

    MPS sengaja tidak digunakan karena htdemucs_ft mengalami
    Metal shader assertion ketika dijalankan melalui Xcode.

    Pada macOS, mode auto akan menggunakan CPU.
    CUDA hanya digunakan jika tersedia pada platform lain.
    """
    import torch

    if requested_device == "cpu":
        return "cpu"

    if requested_device == "cuda":
        if not torch.cuda.is_available():
            raise RuntimeError(
                "CUDA diminta, tetapi CUDA tidak tersedia."
            )

        return "cuda"

    if requested_device == "auto":
        if torch.cuda.is_available():
            return "cuda"

        return "cpu"

    raise ValueError(
        f"Device tidak didukung: {requested_device}"
    )


# ============================================================
# Real chunk progress
# ============================================================

def apply_model_with_progress(
    model: Any,
    normalized_waveform: Any,
    device: str,
) -> Any:
    """
    Menjalankan apply_model() sambil mengubah progress internal
    Demucs menjadi event JSON.

    htdemucs_ft merupakan BagOfModels berisi empat submodel.
    Setiap submodel memproses beberapa chunk audio.

    Progress keseluruhan:

        (submodel_selesai + progress_chunk_submodel_saat_ini)
        -----------------------------------------------------
                        jumlah_submodel
    """
    import demucs.apply as demucs_apply

    if hasattr(model, "models"):
        model_count = len(model.models)
    else:
        model_count = 1

    progress_state: Dict[str, Any] = {
        "progress_bar_index": 0,
        "last_emitted_progress": -1.0,
    }

    original_tqdm = demucs_apply.tqdm.tqdm

    def json_progress_tqdm(
        iterable: Any,
        *args: Any,
        **kwargs: Any,
    ) -> Any:
        """
        Pengganti tqdm.tqdm() yang digunakan apply_model().

        Item dalam iterable merupakan pasangan:
            (future, chunk_offset)

        Event progress dikirim setelah future.result() selesai,
        karena generator dilanjutkan setelah badan for-loop
        Demucs menyelesaikan chunk tersebut.
        """
        items = list(iterable)
        chunk_count = max(len(items), 1)

        progress_bar_index = int(
            progress_state["progress_bar_index"]
        )

        progress_state["progress_bar_index"] = (
            progress_bar_index + 1
        )

        # Secara normal, satu progress bar mewakili satu
        # submodel dalam htdemucs_ft.
        model_index = min(
            progress_bar_index,
            model_count - 1,
        )

        def progress_iterator() -> Any:
            if not items:
                overall_progress = (
                    model_index + 1
                ) / model_count

                emit(
                    {
                        "type": "progress",
                        "progress": round(
                            overall_progress,
                            6,
                        ),
                        "modelIndex": model_index + 1,
                        "modelCount": model_count,
                        "chunkIndex": 0,
                        "chunkCount": 0,
                        "message": (
                            "Separating instruments "
                            f"- model {model_index + 1}"
                            f"/{model_count}"
                        ),
                    }
                )

                return

            for chunk_index, item in enumerate(
                items,
                start=1,
            ):
                # Demucs mengambil item ini, lalu memanggil
                # future.result() dan menggabungkan chunk.
                yield item

                local_progress = (
                    chunk_index / chunk_count
                )

                overall_progress = (
                    model_index + local_progress
                ) / model_count

                overall_progress = min(
                    max(overall_progress, 0.0),
                    1.0,
                )

                last_emitted = float(
                    progress_state[
                        "last_emitted_progress"
                    ]
                )

                # Kirim update jika progress berubah minimal
                # 0.25%, atau chunk terakhir selesai.
                should_emit = (
                    overall_progress - last_emitted
                    >= 0.0025
                    or chunk_index == chunk_count
                )

                if not should_emit:
                    continue

                progress_state[
                    "last_emitted_progress"
                ] = overall_progress

                emit(
                    {
                        "type": "progress",
                        "progress": round(
                            overall_progress,
                            6,
                        ),
                        "modelIndex": model_index + 1,
                        "modelCount": model_count,
                        "chunkIndex": chunk_index,
                        "chunkCount": chunk_count,
                        "message": (
                            "Separating instruments "
                            f"- model {model_index + 1}"
                            f"/{model_count}, "
                            f"chunk {chunk_index}"
                            f"/{chunk_count}"
                        ),
                    }
                )

        return progress_iterator()

    # Demucs 4.0.1 memanggil:
    #
    #     tqdm.tqdm(futures, ...)
    #
    # saat progress=True. Kita menggantinya hanya selama
    # inference ini berlangsung.
    demucs_apply.tqdm.tqdm = json_progress_tqdm

    try:
        return demucs_apply.apply_model(
            model,
            normalized_waveform[None],
            device=device,
            shifts=SHIFTS,
            split=True,
            overlap=OVERLAP,
            progress=True,
            num_workers=NUM_WORKERS,
            segment=SEGMENT,
        )

    finally:
        # kembalikan tqdm
        demucs_apply.tqdm.tqdm = original_tqdm


# ============================================================
# Audio separation
# ============================================================

def separate_audio(
    input_path: Path,
    output_directory: Path,
    requested_device: str,
) -> Dict[str, Any]:
    import torch
    from demucs.pretrained import get_model
    from demucs.separate import load_track

    input_path = input_path.expanduser().resolve()
    output_directory = (
        output_directory.expanduser().resolve()
    )

    if not input_path.is_file():
        raise FileNotFoundError(
            f"File audio tidak ditemukan: {input_path}"
        )

    device = resolve_device(requested_device)

    # --------------------------------------------------------
    # Load model
    # --------------------------------------------------------

    emit(
        {
            "type": "status",
            "stage": "loadingModel",
            "model": MODEL_NAME,
            "device": device,
        }
    )

    model_load_started = time.perf_counter()

    model = get_model(MODEL_NAME)
    model.cpu()
    model.eval()

    model_load_seconds = (
        time.perf_counter() - model_load_started
    )

    actual_stems = set(model.sources)

    if actual_stems != EXPECTED_STEMS:
        raise RuntimeError(
            "Source model tidak sesuai kontrak StemStudio. "
            f"Expected: {sorted(EXPECTED_STEMS)}. "
            f"Actual: {sorted(actual_stems)}."
        )

    # --------------------------------------------------------
    # Load and prepare input audio
    # --------------------------------------------------------

    emit(
        {
            "type": "status",
            "stage": "loadingAudio",
            "model": MODEL_NAME,
        }
    )

    audio_load_started = time.perf_counter()

    # load_track menangani:
    # - decoding MP3/WAV
    # - konversi channel
    # - resampling ke sample rate model
    waveform = load_track(
        input_path,
        model.audio_channels,
        model.samplerate,
    )

    audio_load_seconds = (
        time.perf_counter() - audio_load_started
    )

    if waveform.numel() == 0:
        raise RuntimeError(
            "Audio input tidak memiliki sample."
        )

    # --------------------------------------------------------
    # Normalize input
    # --------------------------------------------------------

    # Pipeline ini mengikuti preprocessing Demucs:
    #
    # ref = waveform.mean(0)
    # waveform -= ref.mean()
    # waveform /= ref.std()
    reference = waveform.mean(0)
    reference_mean = reference.mean()
    reference_std = reference.std()

    if not torch.isfinite(reference_mean):
        raise RuntimeError(
            "Mean waveform tidak valid."
        )

    if not torch.isfinite(reference_std):
        raise RuntimeError(
            "Standard deviation waveform tidak valid."
        )

    normalized_waveform = (
        waveform - reference_mean
    ) / (reference_std + 1e-8)

    # --------------------------------------------------------
    # Demucs inference
    # --------------------------------------------------------

    emit(
        {
            "type": "status",
            "stage": "separating",
            "model": MODEL_NAME,
            "device": device,
        }
    )

    # Beri event 0% khusus untuk inference sebelum chunk
    # pertama selesai.
    emit(
        {
            "type": "progress",
            "progress": 0.0,
            "modelIndex": 1,
            "modelCount": (
                len(model.models)
                if hasattr(model, "models")
                else 1
            ),
            "chunkIndex": 0,
            "chunkCount": 0,
            "message": (
                "Starting instrument separation"
            ),
        }
    )

    inference_started = time.perf_counter()

    with torch.inference_mode():
        separated = apply_model_with_progress(
            model=model,
            normalized_waveform=normalized_waveform,
            device=device,
        )[0]

    inference_seconds = (
        time.perf_counter() - inference_started
    )

    # --------------------------------------------------------
    # Restore original audio scale
    # --------------------------------------------------------

    separated = (
        separated * (reference_std + 1e-8)
    )

    separated = separated + reference_mean

    # --------------------------------------------------------
    # Prepare output directory
    # --------------------------------------------------------

    output_directory.mkdir(
        parents=True,
        exist_ok=True,
    )

    # Hapus output lama agar file dari proses sebelumnya tidak
    # dianggap sebagai hasil separation terbaru.
    for stem_name in EXPECTED_STEMS:
        old_output = (
            output_directory
            / f"{stem_name}.wav"
        )

        if old_output.exists():
            old_output.unlink()

    # --------------------------------------------------------
    # Save output stems
    # --------------------------------------------------------

    emit(
        {
            "type": "status",
            "stage": "saving",
            "model": MODEL_NAME,
        }
    )

    save_started = time.perf_counter()

    outputs: Dict[str, str] = {}

    for source, stem_name in zip(
        separated,
        model.sources,
    ):
        output_path = (
            output_directory
            / f"{stem_name}.wav"
        )

        # Tensor Demucs:
        #     channels x samples
        #
        # SoundFile:
        #     samples x channels
        audio = (
            source
            .detach()
            .cpu()
            .numpy()
            .T
            .astype(
                "float32",
                copy=False,
            )
        )

        sf.write(
            str(output_path),
            audio,
            model.samplerate,
            subtype="FLOAT",
        )

        if not output_path.is_file():
            raise RuntimeError(
                f"Gagal membuat output: {output_path}"
            )

        outputs[stem_name] = str(output_path)

    save_seconds = (
        time.perf_counter() - save_started
    )

    missing_stems = sorted(
        EXPECTED_STEMS.difference(outputs.keys())
    )

    if missing_stems:
        raise RuntimeError(
            "Stem berikut tidak berhasil dibuat: "
            + ", ".join(missing_stems)
        )

    total_seconds = (
        model_load_seconds
        + audio_load_seconds
        + inference_seconds
        + save_seconds
    )

    return {
        "type": "completed",
        "progress": 1.0,
        "model": MODEL_NAME,
        "device": device,
        "sampleRate": int(model.samplerate),
        "audioChannels": int(
            model.audio_channels
        ),
        "sources": list(model.sources),
        "outputs": outputs,
        "timings": {
            "modelLoadSeconds": round(
                model_load_seconds,
                3,
            ),
            "audioLoadSeconds": round(
                audio_load_seconds,
                3,
            ),
            "inferenceSeconds": round(
                inference_seconds,
                3,
            ),
            "saveSeconds": round(
                save_seconds,
                3,
            ),
            "totalSeconds": round(
                total_seconds,
                3,
            ),
        },
        "inferenceConfig": {
            "shifts": SHIFTS,
            "overlap": OVERLAP,
            "segment": SEGMENT,
            "numWorkers": NUM_WORKERS,
        },
        "outputFormat": "WAV float32",
    }


# ============================================================
# CLI
# ============================================================

def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "StemStudio htdemucs_ft inference runner."
        )
    )

    parser.add_argument(
        "--input",
        required=True,
        help="Path file audio MP3 atau WAV.",
    )

    parser.add_argument(
        "--output",
        required=True,
        help="Folder output empat stem WAV.",
    )

    parser.add_argument(
        "--device",
        choices=[
            "auto",
            "cpu",
            "cuda",
        ],
        default="cpu",
        help=(
            "Device inference. Untuk aplikasi macOS "
            "gunakan cpu."
        ),
    )

    return parser.parse_args()


def main() -> int:
    args = parse_arguments()

    try:
        result = separate_audio(
            input_path=Path(args.input),
            output_directory=Path(args.output),
            requested_device=args.device,
        )

        emit(result)
        return 0

    except KeyboardInterrupt:
        emit(
            {
                "type": "cancelled",
                "message": (
                    "Instrument separation dibatalkan."
                ),
            }
        )

        return 130

    except SystemExit as error:
        # load_track() dari Demucs dapat memanggil sys.exit()
        # ketika audio tidak berhasil dibaca.
        exit_code = (
            error.code
            if isinstance(error.code, int)
            else 1
        )

        emit(
            {
                "type": "error",
                "errorType": "SystemExit",
                "message": (
                    "Demucs tidak dapat membaca file audio. "
                    "Pastikan FFmpeg tersedia dan format "
                    "audio didukung."
                ),
            }
        )

        return exit_code

    except Exception as error:
        emit(
            {
                "type": "error",
                "errorType": (
                    type(error).__name__
                ),
                "message": str(error),
            }
        )

        return 1


if __name__ == "__main__":
    sys.exit(main())
