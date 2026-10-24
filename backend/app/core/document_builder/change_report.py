"""Auditoria determinística de patches da Oficina.

Os hashes demonstram quais bytes mudaram; um diff limitado é apenas uma prévia.
Não executa código do projeto nem inspeciona segredos. Não substitui testes.
"""
from __future__ import annotations

import difflib
import hashlib
from pathlib import Path
from typing import Any

from ..code_analyzer.cleaner import is_sensitive_file, should_skip_dir
from .validator import validate_path_safe

MAX_FILES = 12000
MAX_PREVIEW_BYTES = 100_000
MAX_DIFF_LINES = 100


def snapshot_tree(root: Path) -> dict[str, dict[str, Any]]:
    """Calcula hashes por streaming sem carregar o projeto todo na RAM."""
    result: dict[str, dict[str, Any]] = {}
    root = root.resolve()
    for file in sorted(root.rglob('*')):
        if len(result) >= MAX_FILES:
            raise ValueError('Projeto excede o limite de arquivos para auditoria de mudanças')
        if not file.is_file() or file.is_symlink():
            continue
        rel = file.relative_to(root).as_posix()
        if (not validate_path_safe(rel) or is_sensitive_file(rel)
                or any(should_skip_dir(part) for part in file.relative_to(root).parts[:-1])):
            continue
        if not file.resolve().is_relative_to(root):
            continue
        digest = hashlib.sha256()
        size = 0
        with file.open('rb') as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(chunk)
                size += len(chunk)
        result[rel] = {'sha256': digest.hexdigest(), 'bytes': size}
    return result


def compare_snapshots(before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]], *, limit: int = 500) -> dict[str, Any]:
    """Relata arquivos novos, alterados e removidos; nada é marcado como testado."""
    entries = []
    counts = {'added': 0, 'modified': 0, 'deleted': 0}
    for path in sorted(before.keys() | after.keys()):
        previous, current = before.get(path), after.get(path)
        if previous == current:
            continue
        kind = 'added' if previous is None else 'deleted' if current is None else 'modified'
        counts[kind] += 1
        if len(entries) < limit:
            entries.append({'path': path, 'change': kind, 'before': previous, 'after': current})
    return {
        'changed_count': sum(counts.values()), 'counts': counts, 'changes': entries,
        'omitted_change_count': max(0, sum(counts.values()) - len(entries)),
        'verification': 'sha256 dos bytes, não compilação ou teste funcional',
    }


def diff_preview(before: bytes | None, after: bytes | None, path: str) -> str | None:
    """Prévia limitada sem executar código e sem incluir arquivos grandes/binários."""
    if before is not None and len(before) > MAX_PREVIEW_BYTES:
        return None
    if after is not None and len(after) > MAX_PREVIEW_BYTES:
        return None
    if b'\x00' in (before or b'') or b'\x00' in (after or b''):
        return None
    try:
        old = (before or b'').decode('utf-8').splitlines(keepends=True)
        new = (after or b'').decode('utf-8').splitlines(keepends=True)
    except UnicodeDecodeError:
        return None
    lines = difflib.unified_diff(old, new, fromfile=f'a/{path}', tofile=f'b/{path}', n=2)
    out = []
    for i, line in enumerate(lines):
        if i >= MAX_DIFF_LINES:
            out.append('\n... [prévia limitada; obtenha os arquivos para revisar o restante]\n')
            break
        out.append(line)
    return ''.join(out)[:12000]
