"""File Editor — aplica alterações em arquivos de um workspace isolado.

Não altera o original do usuário; trabalha em cópia.

Garantias:
  - o alvo precisa ficar dentro de `root` (inclusive depois de resolver symlinks);
  - symlinks nunca são seguidos para escrita/exclusão;
  - replace/regex só operam em arquivos UTF-8 válidos: arquivos binários ou
    em outra codificação são recusados em vez de corrompidos silenciosamente.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

from .validator import validate_path_safe
from ..code_analyzer.cleaner import is_sensitive_file, should_skip_dir

logger = logging.getLogger(__name__)


def _excluded_path(path_rel: str) -> bool:
    parts = Path(path_rel.replace("\\", "/")).parts
    return is_sensitive_file(path_rel) or any(should_skip_dir(part) for part in parts[:-1])


def _target_inside(root: Path, path_rel: str) -> Path:
    """Resolve root/path_rel garantindo que continua dentro de root."""
    target = root / path_rel
    if target.is_symlink():
        raise ValueError("alvo é um link simbólico; não será alterado")
    try:
        target.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise ValueError("alvo fora do workspace") from exc
    return target


def _read_utf8_text(target: Path) -> str:
    raw = target.read_bytes()
    if b"\x00" in raw[:8192]:
        raise ValueError("arquivo binário; edição de texto recusada")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("arquivo não está em UTF-8; edição recusada para não corromper o conteúdo") from exc


def apply_edits(
    root: Path,
    edits: list[dict[str, Any]],
) -> dict[str, Any]:
    """Aplica lista de edições.

    Cada edit:
      {
        "path": "lib/foo.dart",
        "action": "write" | "replace" | "append" | "delete" | "regex_replace",
        "content": "...",          # write / append
        "old": "...", "new": "...", # replace
        "pattern": "...",          # regex_replace (ou "old")
        "replace_all": true
      }
    """
    applied: list[str] = []
    errors: list[str] = []

    for i, edit in enumerate(edits or []):
        path_rel = (edit.get("path") or "").strip().replace("\\", "/")
        action = (edit.get("action") or "write").strip().lower()

        if not validate_path_safe(path_rel) or _excluded_path(path_rel):
            errors.append(f"[{i}] path inseguro: {path_rel}")
            continue

        try:
            target = _target_inside(root, path_rel)

            if action == "delete":
                if target.is_file():
                    target.unlink()
                    applied.append(f"delete:{path_rel}")
                else:
                    errors.append(f"[{i}] arquivo inexistente para delete: {path_rel}")
                continue

            if action == "write":
                content = edit.get("content")
                if content is None:
                    errors.append(f"[{i}] write sem content: {path_rel}")
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                if isinstance(content, bytes):
                    target.write_bytes(content)
                else:
                    target.write_text(str(content), encoding="utf-8", newline="")
                applied.append(f"write:{path_rel}")
                continue

            if action == "append":
                content = edit.get("content")
                if content is None:
                    errors.append(f"[{i}] append sem content: {path_rel}")
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with open(target, "a", encoding="utf-8", newline="") as f:
                    f.write(str(content))
                applied.append(f"append:{path_rel}")
                continue

            if action == "replace":
                old = edit.get("old")
                new = edit.get("new")
                if old is None or new is None:
                    errors.append(f"[{i}] replace sem old/new: {path_rel}")
                    continue
                old = str(old)
                if old == "":
                    errors.append(f"[{i}] replace com 'old' vazio: {path_rel}")
                    continue
                if not target.is_file():
                    errors.append(f"[{i}] arquivo inexistente: {path_rel}")
                    continue
                text = _read_utf8_text(target)
                if old not in text:
                    errors.append(f"[{i}] trecho não encontrado: {path_rel}")
                    continue
                count = -1 if edit.get("replace_all") else 1
                text = text.replace(old, str(new), count)
                target.write_text(text, encoding="utf-8", newline="")
                applied.append(f"replace:{path_rel}")
                continue

            if action == "regex_replace":
                pattern = edit.get("pattern") or edit.get("old")
                new = edit.get("new", "")
                if not pattern:
                    errors.append(f"[{i}] regex_replace sem pattern: {path_rel}")
                    continue
                if not target.is_file():
                    errors.append(f"[{i}] arquivo inexistente: {path_rel}")
                    continue
                try:
                    compiled = re.compile(str(pattern))
                except re.error as exc:
                    errors.append(f"[{i}] regex inválida: {exc}")
                    continue
                text = _read_utf8_text(target)
                text2, n = compiled.subn(
                    str(new),
                    text,
                    count=0 if edit.get("replace_all") else 1,
                )
                if n == 0:
                    errors.append(f"[{i}] regex sem match: {path_rel}")
                    continue
                target.write_text(text2, encoding="utf-8", newline="")
                applied.append(f"regex_replace:{path_rel}({n})")
                continue

            errors.append(f"[{i}] action desconhecida: {action}")
        except Exception as e:
            errors.append(f"[{i}] {path_rel}: {e}")

    return {"applied": applied, "errors": errors, "ok": len(errors) == 0}


def write_files(root: Path, files: dict[str, str], *, strict: bool = False) -> list[str]:
    """Escreve vários arquivos de uma vez. Retorna paths escritos.

    Paths inseguros ou fora do workspace são ignorados e logados.
    """
    written: list[str] = []
    for rel, content in (files or {}).items():
        rel = rel.strip().replace("\\", "/")
        if not validate_path_safe(rel) or _excluded_path(rel):
            if strict:
                raise ValueError(f"Arquivo extra recusado (caminho inseguro ou sensível): {rel}")
            logger.warning("write_files: path inseguro/sensível ignorado: %r", rel)
            continue
        try:
            target = _target_inside(root, rel)
        except ValueError as exc:
            if strict:
                raise ValueError(f"Arquivo extra {rel} recusado: {exc}") from exc
            logger.warning("write_files: %s: %s", rel, exc)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8", newline="")
        written.append(rel)
    return written
