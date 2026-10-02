"""
Extração de texto de arquivos (PDF, ZIP, texto) e descrição de imagens.
"""

from __future__ import annotations

import io
import logging
import zipfile

from fastapi import APIRouter, File, HTTPException, UploadFile

logger = logging.getLogger(__name__)
router = APIRouter(tags=["extract"])

MAX_BYTES = 8 * 1024 * 1024
MAX_CHARS = 120_000
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic")


def _clip(text: str) -> str:
    text = text.strip()
    if len(text) <= MAX_CHARS:
        return text
    return text[:MAX_CHARS] + "\n\n…[texto cortado por tamanho]"


@router.post("/extract")
async def extract_file(file: UploadFile = File(...)):
    raw = await file.read()
    if len(raw) > MAX_BYTES:
        raise HTTPException(status_code=400, detail="Arquivo maior que 8 MB")

    name = file.filename or "arquivo"
    lower = name.lower()

    try:
        if lower.endswith(".pdf"):
            text = _extract_pdf(raw)
            return {"ok": True, "kind": "pdf", "name": name, "text": _clip(text)}

        if lower.endswith(".zip"):
            text = _extract_zip(raw)
            return {"ok": True, "kind": "zip", "name": name, "text": _clip(text)}

        if any(lower.endswith(ext) for ext in IMAGE_EXTS):
            text = await _describe_image(raw, name)
            return {"ok": True, "kind": "image", "name": name, "text": _clip(text)}

        if any(
            lower.endswith(ext)
            for ext in (
                ".txt",
                ".md",
                ".dart",
                ".py",
                ".json",
                ".yaml",
                ".yml",
                ".csv",
                ".js",
                ".ts",
                ".html",
                ".css",
                ".xml",
                ".sql",
            )
        ):
            text = raw.decode("utf-8", errors="replace")
            return {"ok": True, "kind": "text", "name": name, "text": _clip(text)}

        raise HTTPException(
            status_code=400,
            detail="Tipo não suportado. Use PDF, ZIP, imagem ou texto.",
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("extract failed")
        raise HTTPException(status_code=500, detail=f"Falha na extração: {e}")


async def _describe_image(raw: bytes, name: str) -> str:
    """
    Descrição de imagem simplificada (sem OpenRouter).
    Retorna apenas metadados + orientação para o usuário descrever.
    """
    meta = _image_meta(raw, name)
    return (
        f"{meta}\n\n"
        "Descrição automática de imagem desativada (OpenRouter removido). "
        "Peça ao usuário para descrever o que vê na imagem."
    )



def _image_meta(raw: bytes, name: str) -> str:
    w = h = None
    try:
        # PNG
        if raw[:8] == b"\x89PNG\r\n\x1a\n" and len(raw) >= 24:
            w = int.from_bytes(raw[16:20], "big")
            h = int.from_bytes(raw[20:24], "big")
        # JPEG SOF
        elif raw[:2] == b"\xff\xd8":
            i = 2
            while i < len(raw) - 8:
                if raw[i] != 0xFF:
                    i += 1
                    continue
                marker = raw[i + 1]
                if marker in (0xC0, 0xC1, 0xC2):
                    h = int.from_bytes(raw[i + 5 : i + 7], "big")
                    w = int.from_bytes(raw[i + 7 : i + 9], "big")
                    break
                length = int.from_bytes(raw[i + 2 : i + 4], "big")
                i += 2 + length
    except Exception:
        pass
    size = f"{len(raw)} bytes"
    dim = f"{w}x{h}px" if w and h else "dimensão desconhecida"
    return f"[Imagem: {name} · {dim} · {size}]"


def _extract_pdf(raw: bytes) -> str:
    try:
        from pypdf import PdfReader
    except ImportError as e:
        raise RuntimeError("pypdf não instalado. Rode: pip install pypdf") from e

    reader = PdfReader(io.BytesIO(raw))
    parts = []
    for i, page in enumerate(reader.pages):
        try:
            t = page.extract_text() or ""
        except Exception:
            t = ""
        if t.strip():
            parts.append(f"--- Página {i + 1} ---\n{t}")
    return "\n\n".join(parts) if parts else ""


def _extract_zip(raw: bytes) -> str:
    text_exts = {
        ".dart",
        ".py",
        ".js",
        ".ts",
        ".json",
        ".md",
        ".txt",
        ".yaml",
        ".yml",
        ".html",
        ".css",
        ".xml",
        ".sql",
        ".sh",
    }
    parts = []
    total = 0
    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = info.filename
            if "__MACOSX" in name:
                continue
            lower = name.lower()
            if not any(lower.endswith(ext) for ext in text_exts):
                continue
            try:
                data = zf.read(info)
                text = data.decode("utf-8", errors="replace")
            except Exception:
                continue
            if total + len(text) > MAX_CHARS:
                parts.append("…[limite do ZIP]")
                break
            parts.append(f"### {name}\n```\n{text}\n```")
            total += len(text)
    return "\n\n".join(parts)
