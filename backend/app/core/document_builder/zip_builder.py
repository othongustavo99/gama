"""ZIP Builder — cria e recompacta arquivos de forma segura."""

from __future__ import annotations

import io
import logging
import shutil
import zipfile
from pathlib import Path
from typing import Any, Optional

from .validator import validate_path_safe, validate_zip

logger = logging.getLogger(__name__)

# diretórios que normalmente não entram no ZIP de entrega
DEFAULT_SKIP_DIRS = {
    ".git",
    ".svn",
    ".hg",
    ".dart_tool",
    ".idea",
    ".vscode",
    "__pycache__",
    ".pytest_cache",
    "node_modules",
    "Pods",
    "build",
    "dist",
    ".gradle",
    ".next",
    "coverage",
    "venv",
    ".venv",
    "DerivedData",
}


def _should_skip(rel: str, skip_dirs: set[str], include_junk: bool) -> bool:
    if include_junk:
        return False
    parts = Path(rel).parts
    return any(p in skip_dirs for p in parts)


def build_zip_from_directory(
    root: Path,
    *,
    arc_prefix: str = "",
    skip_dirs: Optional[set[str]] = None,
    include_junk: bool = False,
    max_file_size: int = 5 * 1024 * 1024,
    max_total: int = 80 * 1024 * 1024,
) -> bytes:
    """Compacta um diretório em bytes ZIP."""
    skip = skip_dirs if skip_dirs is not None else DEFAULT_SKIP_DIRS
    buf = io.BytesIO()
    total = 0
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            try:
                rel = path.relative_to(root).as_posix()
            except ValueError:
                continue
            if not validate_path_safe(rel):
                continue
            if _should_skip(rel, skip, include_junk):
                continue
            size = path.stat().st_size
            if size > max_file_size:
                logger.debug("skip large file %s (%s)", rel, size)
                continue
            if total + size > max_total:
                logger.warning("ZIP: limite total atingido em %s", rel)
                break
            arcname = f"{arc_prefix.rstrip('/')}/{rel}" if arc_prefix else rel
            try:
                zf.write(path, arcname=arcname)
                total += size
            except Exception as e:
                logger.debug("skip write %s: %s", rel, e)
    data = buf.getvalue()
    result = validate_zip(data)
    if not result["ok"]:
        raise ValueError(f"ZIP gerado inválido: {result['errors']}")
    return data


def build_zip_from_mapping(
    files: dict[str, str | bytes],
    *,
    max_total: int = 80 * 1024 * 1024,
) -> bytes:
    """Cria ZIP a partir de {path_relativo: conteúdo}."""
    buf = io.BytesIO()
    total = 0
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for rel, content in files.items():
            if not validate_path_safe(rel):
                raise ValueError(f"Path inseguro: {rel}")
            if isinstance(content, str):
                raw = content.encode("utf-8")
            else:
                raw = content
            if total + len(raw) > max_total:
                raise ValueError("Conteúdo excede limite do ZIP")
            zf.writestr(rel.replace("\\", "/"), raw)
            total += len(raw)
    data = buf.getvalue()
    result = validate_zip(data)
    if not result["ok"]:
        raise ValueError(f"ZIP gerado inválido: {result['errors']}")
    return data


def extract_zip_safe(
    zip_bytes: bytes,
    dest: Path,
    *,
    max_files: int = 8000,
    max_single: int = 5 * 1024 * 1024,
    max_total: int = 80 * 1024 * 1024,
) -> int:
    """Extrai ZIP com proteções (path traversal, limites)."""
    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    total = 0
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if count >= max_files:
                break
            name = info.filename.replace("\\", "/")
            if not validate_path_safe(name):
                continue
            if info.file_size > max_single:
                continue
            if total + info.file_size > max_total:
                break
            target = dest / name
            # garante que target está dentro de dest
            try:
                target.resolve().relative_to(dest.resolve())
            except ValueError:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, open(target, "wb") as out:
                out.write(src.read())
            count += 1
            total += info.file_size
    return count


def copy_tree_filtered(
    src: Path,
    dest: Path,
    *,
    skip_dirs: Optional[set[str]] = None,
    include_junk: bool = False,
) -> int:
    """Copia árvore filtrando junk. Retorna número de arquivos."""
    skip = skip_dirs if skip_dirs is not None else DEFAULT_SKIP_DIRS
    dest.mkdir(parents=True, exist_ok=True)
    n = 0
    for path in src.rglob("*"):
        if not path.is_file():
            continue
        try:
            rel = path.relative_to(src).as_posix()
        except ValueError:
            continue
        if not validate_path_safe(rel):
            continue
        if _should_skip(rel, skip, include_junk):
            continue
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        n += 1
    return n
