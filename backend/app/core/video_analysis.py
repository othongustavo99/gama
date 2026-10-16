"""Extração limitada de quadros-chave para compreender um vídeo anexado."""
from __future__ import annotations

import base64
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

MAX_VIDEO_BYTES = 50 * 1024 * 1024
MAX_VIDEO_SECONDS = 300
MAX_FRAMES = 8
VIDEO_REFERENCE_MIN_SECONDS = 2
VIDEO_REFERENCE_MAX_SECONDS = 15


def _probe_duration(path: Path) -> float:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        raise RuntimeError("O backend não tem ffprobe instalado para validar a duração do vídeo.")
    probe = subprocess.run(
        [
            ffprobe,
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    if probe.returncode != 0:
        raise ValueError("O arquivo anexado não parece ser um vídeo válido.")
    try:
        duration = float(probe.stdout.strip())
    except (TypeError, ValueError):
        duration = 0.0
    if duration <= 0:
        raise ValueError("Não consegui identificar a duração do vídeo.")
    return duration


def validate_video_reference_duration(duration: float) -> None:
    """Valida a duração da referência enviada ao modelo Seedance 2.0 Mini."""
    if duration < VIDEO_REFERENCE_MIN_SECONDS:
        raise ValueError("Para editar com vídeo de referência, envie um clipe de pelo menos 2 segundos.")
    if duration > VIDEO_REFERENCE_MAX_SECONDS:
        raise ValueError(
            "O modelo de vídeo aceita referências de até 15 segundos. "
            "Recorte o trecho que deseja editar e anexe-o novamente; o vídeo original não foi alterado."
        )


def prepare_video_reference(video_path: str | Path) -> tuple[bytes, dict[str, Any]]:
    """Normaliza uma referência curta para MP4/H.264, sem modificar o original."""
    path = Path(video_path)
    if not path.is_file() or path.stat().st_size <= 0:
        raise ValueError("O vídeo de referência não existe ou está vazio.")
    if path.stat().st_size > MAX_VIDEO_BYTES:
        raise ValueError("O vídeo excede o limite de 50 MiB.")
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("O backend não tem ffmpeg instalado para preparar o vídeo de referência.")
    duration = _probe_duration(path)
    validate_video_reference_duration(duration)

    with tempfile.TemporaryDirectory(prefix="gama_video_ref_") as tmp:
        output = Path(tmp) / "video_reference.mp4"
        result = subprocess.run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-i", str(path), "-map", "0:v:0", "-map", "0:a?",
                "-vf", "scale=1280:1280:force_original_aspect_ratio=decrease",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
                "-movflags", "+faststart", str(output),
            ],
            capture_output=True, text=True, timeout=90, check=False,
        )
        if result.returncode != 0 or not output.is_file():
            raise ValueError("Não consegui preparar o vídeo para edição. Tente MP4/H.264 de até 15 segundos.")
        data = output.read_bytes()
        if len(data) < 128 or len(data) > MAX_VIDEO_BYTES or data[4:8] != b"ftyp":
            raise ValueError("O vídeo preparado ficou vazio ou ultrapassou 50 MiB. Tente um clipe mais curto ou menor.")
        return data, {"duration_seconds": round(duration, 2), "format": "mp4/h264"}


def extract_video_frames(video_path: str | Path) -> tuple[list[dict[str, str]], dict[str, Any]]:
    path = Path(video_path)
    if not path.is_file() or path.stat().st_size <= 0:
        raise ValueError("O arquivo de vídeo não existe ou está vazio.")
    if path.stat().st_size > MAX_VIDEO_BYTES:
        raise ValueError("O vídeo excede o limite de 50 MiB.")
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise RuntimeError("O backend não tem ffmpeg/ffprobe instalado para analisar vídeos.")

    duration = _probe_duration(path)
    if duration > MAX_VIDEO_SECONDS:
        raise ValueError("Para manter a análise rápida, envie vídeos de até 5 minutos.")

    with tempfile.TemporaryDirectory(prefix="gama_video_") as tmp:
        output_pattern = str(Path(tmp) / "frame_%02d.jpg")
        # Um quadro a cada ~5 segundos, com no máximo 8 quadros e dimensão reduzida.
        fps = min(1 / 2, MAX_FRAMES / max(duration, 1.0))
        filt = f"fps={fps:.6f},scale=768:768:force_original_aspect_ratio=decrease"
        result = subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(path), "-vf", filt, "-frames:v", str(MAX_FRAMES), "-q:v", "4", output_pattern, "-y"],
            capture_output=True, timeout=45, check=False,
        )
        if result.returncode != 0:
            raise ValueError("Não consegui extrair quadros do vídeo. Tente converter para MP4/H.264.")
        files = sorted(Path(tmp).glob("frame_*.jpg"))[:MAX_FRAMES]
        if not files:
            raise ValueError("Não consegui obter quadros visuais desse vídeo.")
        frames = []
        for index, frame in enumerate(files):
            frames.append({
                "name": f"video_frame_{index + 1:02d}.jpg",
                "mime": "image/jpeg",
                "data": base64.b64encode(frame.read_bytes()).decode("ascii"),
            })
        return frames, {"duration_seconds": round(duration, 2), "frames_analyzed": len(frames)}
