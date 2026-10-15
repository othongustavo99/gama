"""Valida ZIP e PDF antes de entregar ao usuário."""

from __future__ import annotations

import io
import logging
import re
import stat
import zipfile
from typing import Any

logger = logging.getLogger(__name__)

MAX_ZIP_SIZE = 100 * 1024 * 1024  # 100 MB
MAX_PDF_SIZE = 50 * 1024 * 1024
MAX_ZIP_ENTRIES = 12_000

_WINDOWS_DRIVE_RE = re.compile(r"^[A-Za-z]:")
_CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")


def _is_symlink_entry(info: zipfile.ZipInfo) -> bool:
    mode = (info.external_attr >> 16) & 0xFFFF
    return stat.S_ISLNK(mode)


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

            infos = zf.infolist()
            names = [i.filename for i in infos]
            if len(names) > MAX_ZIP_ENTRIES:
                errors.append(f"Muitas entradas no ZIP ({len(names)})")

            for info in infos:
                name = info.filename
                norm = name.replace("\\", "/")
                if (
                    norm.startswith("/")
                    or _WINDOWS_DRIVE_RE.match(norm)
                    or ".." in norm.split("/")
                    or _CONTROL_CHARS_RE.search(norm)
                ):
                    errors.append(f"Path perigoso: {name!r}")
                if _is_symlink_entry(info):
                    # Links simbólicos podem apontar para fora do projeto ao extrair.
                    errors.append(f"Link simbólico não é permitido no ZIP: {name!r}")

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
    """True se o path relativo é seguro: sem traversal, sem absoluto, sem drive, sem controles."""
    if not rel or not isinstance(rel, str):
        return False
    norm = rel.replace("\\", "/").strip()
    if not norm:
        return False
    if norm.startswith("/") or norm.startswith("~") or _WINDOWS_DRIVE_RE.match(norm):
        return False
    if _CONTROL_CHARS_RE.search(norm):
        return False
    parts = norm.split("/")
    if any(p == ".." for p in parts):
        return False
    # ignora segmentos vazios/"." apenas para validar que sobra algum nome real
    if not any(p not in ("", ".") for p in parts):
        return False
    return True


def validate_source_archive(data: bytes, *, max_files: int = 500, max_file_bytes: int = 2 * 1024 * 1024) -> dict[str, Any]:
    """Valida sintaxe de formatos suportados sem executar código do projeto.

    Verifica Python, JSON/JSONL básico, XML/SVG e TOML quando a stdlib oferece
    parser. Linguagens sem parser seguro disponível são listadas como não
    verificadas; não se declara que o ZIP inteiro compila.
    """
    import ast
    import json
    from pathlib import PurePosixPath
    import xml.etree.ElementTree as ET

    issues: list[dict[str, Any]] = []
    skipped: list[dict[str, str]] = []
    checked: list[str] = []
    supported = {".py", ".json", ".ipynb", ".xml", ".svg", ".plist", ".toml"}

    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            candidates = [info for info in archive.infolist() if not info.is_dir()]
            processed = 0
            for info in candidates:
                path = info.filename.replace("\\", "/")
                ext = PurePosixPath(path).suffix.lower()
                if ext not in supported:
                    continue
                if processed >= max_files:
                    skipped.append({"path": path, "reason": "limite de arquivos verificados"})
                    continue
                processed += 1
                if info.file_size > max_file_bytes:
                    skipped.append({"path": path, "reason": "arquivo grande demais para validação sintática"})
                    continue
                try:
                    raw = archive.read(info)
                    text = raw.decode("utf-8-sig")
                    if ext == ".py":
                        ast.parse(text, filename=path)
                    elif ext in {".json", ".ipynb"}:
                        json.loads(text)
                    elif ext in {".xml", ".svg", ".plist"}:
                        ET.fromstring(text)
                    elif ext == ".toml":
                        try:
                            import tomllib
                        except ImportError:
                            skipped.append({"path": path, "reason": "tomllib indisponível neste Python"})
                            continue
                        tomllib.loads(text)
                    checked.append(path)
                except (UnicodeDecodeError, SyntaxError, json.JSONDecodeError, ET.ParseError, ValueError) as exc:
                    issues.append({
                        "path": path,
                        "line": getattr(exc, "lineno", None),
                        "message": str(exc).splitlines()[0][:300],
                        "validator": ext.lstrip("."),
                    })
                except Exception as exc:  # parser inesperado não pode derrubar a geração do artefato
                    skipped.append({"path": path, "reason": f"falha no validador: {type(exc).__name__}"})
    except (zipfile.BadZipFile, OSError) as exc:
        return {"ok": False, "checked_count": 0, "checked_paths": [], "issues": [{"path": "", "line": None, "message": f"ZIP inválido: {exc}"}], "skipped": []}

    return {
        "ok": not issues,
        "status": "passed" if not issues else "issues_found",
        "checked_count": len(checked),
        "checked_paths": checked[:200],
        "issues": issues[:200],
        "issue_count": len(issues),
        "skipped": skipped[:200],
        "skipped_count": len(skipped),
        "note": "Esta validação sintática não substitui flutter analyze, testes, compilação ou revisão humana.",
    }
