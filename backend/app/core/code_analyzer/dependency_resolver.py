"""Resolve referências: se achou authService.login, puxa AuthService, ApiService, etc."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from .code_search import search_by_symbol
from .mapper import extract_imports, extract_symbols


def _local_refs(text: str) -> list[str]:
    """Nomes de classes/serviços/funções referenciados no trecho."""
    refs: list[str] = []
    # CamelCase identifiers (classes/services)
    for m in re.finditer(r"\b([A-Z][a-zA-Z0-9]{2,})\b", text):
        n = m.group(1)
        if n not in refs and n not in {"Future", "String", "List", "Map", "Widget", "BuildContext", "State", "StatelessWidget", "StatefulWidget"}:
            refs.append(n)
    # snake_case service-like
    for m in re.finditer(r"\b([a-z][a-z0-9_]{3,}(?:Service|Client|Provider|Controller|Manager|Repo|Repository|Api|API))\b", text):
        n = m.group(1)
        if n not in refs:
            refs.append(n)
    return refs[:25]


def resolve_dependencies(
    root: Path,
    ranked: list[dict[str, Any]],
    symbol_index: dict[str, list[str]],
    file_metas: list[dict[str, Any]],
    *,
    max_extra: int = 8,
) -> list[dict[str, Any]]:
    """A partir dos arquivos já ranqueados, adiciona dependências diretas."""
    have = {r["path"] for r in ranked}
    extra: list[dict[str, Any]] = []
    path_by_name: dict[str, str] = {}

    # mapa simples: nome de arquivo base → path
    for fm in file_metas:
        base = Path(fm["path"]).stem.lower()
        path_by_name.setdefault(base, fm["path"])
        # também class-like: auth_service → AuthService
        camel = "".join(p.capitalize() for p in base.split("_"))
        path_by_name.setdefault(camel.lower(), fm["path"])

    for item in ranked[:10]:
        text = item.get("text") or ""
        refs = _local_refs(text[:30_000])
        imports = extract_imports(text[:20_000])

        candidates: list[str] = []
        for ref in refs:
            # busca no symbol index
            for p in search_by_symbol(symbol_index, ref):
                if p not in have:
                    candidates.append(p)
            # heurística por nome de arquivo
            key = ref.lower()
            if key in path_by_name and path_by_name[key] not in have:
                candidates.append(path_by_name[key])
            # snake
            snake = re.sub(r"(?<!^)(?=[A-Z])", "_", ref).lower()
            if snake in path_by_name and path_by_name[snake] not in have:
                candidates.append(path_by_name[snake])

        for imp in imports:
            # package:foo/bar.dart → bar
            part = imp.split("/")[-1].replace(".dart", "").replace(".py", "")
            part_l = part.lower()
            if part_l in path_by_name and path_by_name[part_l] not in have:
                candidates.append(path_by_name[part_l])

        for cand in candidates:
            if cand in have or len(extra) >= max_extra:
                continue
            p = root / cand
            if not p.is_file():
                continue
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
            except Exception:
                continue
            if len(text) > 200_000:
                text = text[:200_000]
            extra.append(
                {
                    "path": cand,
                    "score": 50.0,
                    "important": True,
                    "text": text,
                    "preview": text[:400],
                    "via_dependency": True,
                }
            )
            have.add(cand)

    return ranked + extra
