"""Valida ZIP e PDF antes de entregar ao usuário."""

from __future__ import annotations

import io
import logging
import zipfile
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

MAX_ZIP_SIZE = 100 * 1024 * 1024  # 100 MB
MAX_PDF_SIZE = 50 * 1024 * 1024
MAX_ZIP_ENTRIES = 12_000


def validate_zip(data: bytes, *, expected_paths: list[str] | None = None) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    if not data:
        return {"ok": False, "errors": ["ZIP vazio"], "warnings": [], "entry_count": 0}

    if len(data) > MAX_ZIP_SIZE:
        errors.append(f"ZIP maior que {MAX_ZIP_SIZE // (1024*1024)} MB")

    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            bad = zf.testzip()
            if bad is not None:
                errors.append(f"Arquivo corrompido no ZIP: {bad}")

            names = zf.namelist()
            if len(names) > MAX_ZIP_ENTRIES:
                errors.append(f"Muitas entradas no ZIP ({len(names)})")

            for name in names:
                norm = name.replace("\\", "/")
                if norm.startswith("/") or ".." in norm.split("/"):
                    errors.append(f"Path perigoso: {name}")

            if expected_paths:
                have = {n.replace("\\", "/").lstrip("./") for n in names}
                for ep in expected_paths:
                    epn = ep.replace("\\", "/").lstrip("./")
                    if epn not in have and not any(h.endswith(epn) for h in have):
                        warnings.append(f"Arquivo esperado ausente: {ep}")

            return {
                "ok": len(errors) == 0,
                "errors": errors,
                "warnings": warnings,
                "entry_count": len(names),
                "sample": names[:30],
                "size": len(data),
            }
    except zipfile.BadZipFile as e:
        return {"ok": False, "errors": [f"ZIP inválido: {e}"], "warnings": [], "entry_count": 0}
    except Exception as e:
        return {"ok": False, "errors": [f"Falha ao validar ZIP: {e}"], "warnings": [], "entry_count": 0}


def validate_pdf(data: bytes, *, min_pages: int = 1) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    if not data:
        return {"ok": False, "errors": ["PDF vazio"], "warnings": [], "pages": 0}

    if len(data) > MAX_PDF_SIZE:
        errors.append(f"PDF maior que {MAX_PDF_SIZE // (1024*1024)} MB")

    if not data.startswith(b"%PDF"):
        errors.append("Assinatura PDF inválida (não começa com %PDF)")

    try:
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(data))
        n = len(reader.pages)
        if n < min_pages:
            errors.append(f"PDF com poucas páginas ({n} < {min_pages})")

        # tenta extrair texto da 1ª página
        text_sample = ""
        if n > 0:
            try:
                text_sample = (reader.pages[0].extract_text() or "")[:200]
            except Exception:
                warnings.append("Não foi possível extrair texto da 1ª página")

        return {
            "ok": len(errors) == 0,
            "errors": errors,
            "warnings": warnings,
            "pages": n,
            "size": len(data),
            "text_sample": text_sample,
        }
    except Exception as e:
        # se pypdf falhar mas assinatura ok, ainda pode ser utilizável
        if data.startswith(b"%PDF") and not errors:
            warnings.append(f"pypdf não abriu completamente: {e}")
            return {
                "ok": True,
                "errors": [],
                "warnings": warnings,
                "pages": -1,
                "size": len(data),
            }
        return {"ok": False, "errors": [f"PDF inválido: {e}"], "warnings": warnings, "pages": 0}


def validate_path_safe(rel: str) -> bool:
    """True se o path relativo é seguro (sem traversal)."""
    if not rel or not isinstance(rel, str):
        return False
    norm = rel.replace("\\", "/").strip()
    if norm.startswith("/") or norm.startswith("~"):
        return False
    parts = norm.split("/")
    if any(p == ".." for p in parts):
        return False
    return True
