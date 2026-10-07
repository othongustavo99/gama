"""File Editor — aplica alterações em arquivos de um workspace isolado.

Não altera o original do usuário; trabalha em cópia.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any, Optional

from .validator import validate_path_safe

logger = logging.getLogger(__name__)


def apply_edits(
    root: Path,
    edits: list[dict[str, Any]],
) -> dict[str, Any]:
    """Aplica lista de edições.

    Cada edit:
      {
        "path": "lib/foo.dart",
        "action": "write" | "replace" | "append" | "delete",
        "content": "...",          # write / append
        "old": "...", "new": "...", # replace
        "replace_all": true
      }
    """
    applied: list[str] = []
    errors: list[str] = []

    for i, edit in enumerate(edits or []):
        path_rel = (edit.get("path") or "").strip().replace("\\", "/")
        action = (edit.get("action") or "write").strip().lower()

        if not validate_path_safe(path_rel):
            errors.append(f"[{i}] path inseguro: {path_rel}")
            continue

        target = root / path_rel

        try:
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
                    target.write_text(str(content), encoding="utf-8")
                applied.append(f"write:{path_rel}")
                continue

            if action == "append":
                content = edit.get("content")
                if content is None:
                    errors.append(f"[{i}] append sem content: {path_rel}")
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with open(target, "a", encoding="utf-8") as f:
                    f.write(str(content))
                applied.append(f"append:{path_rel}")
                continue

            if action == "replace":
                old = edit.get("old")
                new = edit.get("new")
                if old is None or new is None:
                    errors.append(f"[{i}] replace sem old/new: {path_rel}")
                    continue
                if not target.is_file():
                    errors.append(f"[{i}] arquivo inexistente: {path_rel}")
                    continue
                text = target.read_text(encoding="utf-8", errors="replace")
                if edit.get("replace_all"):
                    if old not in text:
                        errors.append(f"[{i}] trecho não encontrado (replace_all): {path_rel}")
                        continue
                    text = text.replace(str(old), str(new))
                else:
                    if str(old) not in text:
                        errors.append(f"[{i}] trecho não encontrado: {path_rel}")
                        continue
                    text = text.replace(str(old), str(new), 1)
                target.write_text(text, encoding="utf-8")
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
                text = target.read_text(encoding="utf-8", errors="replace")
                text2, n = re.subn(
                    pattern,
                    str(new),
                    text,
                    count=0 if edit.get("replace_all") else 1,
                )
                if n == 0:
                    errors.append(f"[{i}] regex sem match: {path_rel}")
                    continue
                target.write_text(text2, encoding="utf-8")
                applied.append(f"regex_replace:{path_rel}({n})")
                continue

            errors.append(f"[{i}] action desconhecida: {action}")
        except Exception as e:
            errors.append(f"[{i}] {path_rel}: {e}")

    return {"applied": applied, "errors": errors, "ok": len(errors) == 0}


def write_files(root: Path, files: dict[str, str]) -> list[str]:
    """Escreve vários arquivos de uma vez. Retorna paths escritos."""
    written: list[str] = []
    for rel, content in (files or {}).items():
        rel = rel.strip().replace("\\", "/")
        if not validate_path_safe(rel):
            continue
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        written.append(rel)
    return written
