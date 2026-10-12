"""ZIP Builder — cria e recompacta arquivos de forma segura.

Regras de segurança aplicadas em todas as entradas:
  - nada de symlink (nem na entrada, nem em diretório intermediário);
  - caminho resolvido precisa continuar dentro da raiz de origem/destino;
  - limites de tamanho medidos pelos bytes realmente lidos, não pelo cabeçalho.

Quando algum arquivo é pulado (limite, symlink, erro) o relatório registra
o motivo, para que nada seja perdido em silêncio.
"""

from __future__ import annotations

import io
import logging
import shutil
import stat
import zipfile
from pathlib import Path
from typing import Any, Optional

from ..code_analyzer.cleaner import should_skip_dir
from .validator import validate_path_safe, validate_zip

logger = logging.getLogger(__name__)

_CHUNK = 1024 * 1024


def _should_skip(rel: str, skip_dirs: Optional[set[str]], include_junk: bool) -> bool:
    """Junk de diretório. Usa a MESMA lista da análise (code_analyzer.cleaner).

    `skip_dirs` explícito continua aceito, para chamadas especiais.
    """
    if include_junk:
        return False
    dirs = Path(rel).parts[:-1]  # só diretórios; o nome do arquivo não conta
    if skip_dirs is not None:
        return any(d in skip_dirs for d in dirs)
    return any(should_skip_dir(d) for d in dirs)


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (ValueError, OSError):
        return False


def _has_symlink_in_chain(path: Path, root: Path) -> bool:
    """True se o próprio arquivo ou algum diretório entre root e path é symlink."""
    current = path
    while current != root and root in current.parents:
        if current.is_symlink():
            return True
        current = current.parent
    return path.is_symlink()


def build_zip_with_report(
    root: Path,
    *,
    arc_prefix: str = "",
    skip_dirs: Optional[set[str]] = None,
    include_junk: bool = False,
    max_file_size: int = 8 * 1024 * 1024,  # era 5 MB
    max_total: int = 100 * 1024 * 1024,  # era 80 MB
) -> tuple[bytes, dict[str, Any]]:
    """Compacta um diretório. Retorna (bytes_zip, relatório)."""
    skip = skip_dirs
    report: dict[str, Any] = {
        "included": 0,
        "skipped": [],  # [{"path": ..., "reason": ...}]
        "truncated": False,
        "total_bytes": 0,
    }
    buf = io.BytesIO()
    total = 0
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(root.rglob("*")):
            try:
                rel = path.relative_to(root).as_posix()
            except ValueError:
                continue
            if path.is_dir() and not path.is_symlink():
                continue
            if not validate_path_safe(rel):
                report["skipped"].append({"path": rel, "reason": "caminho inseguro"})
                continue
            if _should_skip(rel, skip, include_junk):
                continue
            if _has_symlink_in_chain(path, root):
                report["skipped"].append({"path": rel, "reason": "symlink"})
                continue
            if not path.is_file() or not _inside(path, root):
                continue
            try:
                size = path.stat().st_size
            except OSError as e:
                report["skipped"].append({"path": rel, "reason": f"stat: {e}"})
                continue
            if size > max_file_size:
                report["skipped"].append({"path": rel, "reason": f"maior que {max_file_size} bytes"})
                continue
            if total + size > max_total:
                report["truncated"] = True
                report["skipped"].append({"path": rel, "reason": "limite total do ZIP atingido"})
                logger.warning("ZIP: limite total atingido em %s", rel)
                continue
            arcname = f"{arc_prefix.rstrip('/')}/{rel}" if arc_prefix else rel
            try:
                zf.write(path, arcname=arcname)
                total += size
                report["included"] += 1
            except Exception as e:
                report["skipped"].append({"path": rel, "reason": f"erro ao escrever: {e}"})
                logger.debug("skip write %s: %s", rel, e)
    data = buf.getvalue()
    report["total_bytes"] = total
    result = validate_zip(data)
    report["validation"] = result
    if not result["ok"]:
        raise ValueError(f"ZIP gerado inválido: {result['errors']}")
    return data, report


def build_zip_from_directory(
    root: Path,
    *,
    arc_prefix: str = "",
    skip_dirs: Optional[set[str]] = None,
    include_junk: bool = False,
    max_file_size: int = 8 * 1024 * 1024,
    max_total: int = 100 * 1024 * 1024,
) -> bytes:
    """Compatibilidade: retorna só os bytes do ZIP."""
    data, _ = build_zip_with_report(
        root,
        arc_prefix=arc_prefix,
        skip_dirs=skip_dirs,
        include_junk=include_junk,
        max_file_size=max_file_size,
        max_total=max_total,
    )
    return data


def build_zip_from_mapping(
    files: dict[str, str | bytes],
    *,
    max_total: int = 100 * 1024 * 1024,
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
    max_single: int = 8 * 1024 * 1024,
    max_total: int = 100 * 1024 * 1024,
) -> int:
    """Extrai ZIP com proteções (traversal, symlink, limites reais de leitura)."""
    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    total = 0
    dest_resolved = dest.resolve()
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if count >= max_files:
                logger.warning("ZIP: limite de %s arquivos atingido", max_files)
                break
            if stat.S_ISLNK((info.external_attr >> 16) & 0xFFFF):
                logger.warning("ZIP: link simbólico ignorado: %r", info.filename)
                continue
            name = info.filename.replace("\\", "/")
            if not validate_path_safe(name):
                logger.warning("ZIP: caminho inseguro ignorado: %r", info.filename)
                continue
            if info.file_size > max_single:
                continue
            if total + info.file_size > max_total:
                logger.warning("ZIP: limite total descompactado atingido")
                break
            target = dest / name
            try:
                target.resolve().relative_to(dest_resolved)
            except ValueError:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            # Lê em blocos e para no limite real: o cabeçalho pode mentir (zip bomb).
            written = 0
            try:
                with zf.open(info) as src, open(target, "wb") as out:
                    while True:
                        chunk = src.read(_CHUNK)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > max_single or total + written > max_total:
                            raise ValueError("tamanho real excede o limite")
                        out.write(chunk)
            except (ValueError, OSError, zipfile.BadZipFile) as e:
                logger.warning("ZIP: falha/limite ao extrair %r: %s", info.filename, e)
                target.unlink(missing_ok=True)
                continue
            count += 1
            total += written
    return count


def copy_tree_filtered(
    src: Path,
    dest: Path,
    *,
    skip_dirs: Optional[set[str]] = None,
    include_junk: bool = False,
) -> int:
    """Copia árvore filtrando junk e symlinks. Retorna número de arquivos."""
    skip = skip_dirs
    dest.mkdir(parents=True, exist_ok=True)
    n = 0
    for path in src.rglob("*"):
        try:
            rel = path.relative_to(src).as_posix()
        except ValueError:
            continue
        if path.is_dir() and not path.is_symlink():
            continue
        if not path.is_file() or _has_symlink_in_chain(path, src):
            continue
        if not validate_path_safe(rel) or not _inside(path, src):
            continue
        if _should_skip(rel, skip, include_junk):
            continue
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        n += 1
    return n
