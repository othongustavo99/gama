"""
Extração de texto de arquivos (PDF, etc.) para o chat da Gamma.
"""

from __future__ import annotations

import io
import zipfile
from typing import Optional

from fastapi import APIRouter, File, HTTPException, UploadFile

router = APIRouter(tags=["extract"])

MAX_BYTES = 8 * 1024 * 1024
MAX_CHARS = 120_000


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

        # texto simples
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
            )
        ):
            text = raw.decode("utf-8", errors="replace")
            return {"ok": True, "kind": "text", "name": name, "text": _clip(text)}

        raise HTTPException(
            status_code=400,
            detail="Tipo não suportado neste endpoint. Use PDF, ZIP ou texto.",
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Falha na extração: {e}")


def _extract_pdf(raw: bytes) -> str:
    try:
        from pypdf import PdfReader
    except ImportError as e:
        raise RuntimeError(
            "pypdf não instalado. Rode: pip install pypdf"
        ) from e

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
