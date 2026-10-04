"""Monta contexto relevante dentro de um orçamento de caracteres (≈ tokens)."""

from __future__ import annotations

from pathlib import Path
from typing import Any


def _budget_chars(max_tokens: int) -> int:
    # ~3.5 chars/token conservative for code
    return max(2000, int(max_tokens * 3.2))


def _smart_clip(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    # prefer head + tail for structure
    head = int(max_chars * 0.7)
    tail = max_chars - head - 40
    if tail < 200:
        return text[:max_chars] + "\n…[cortado]"
    return text[:head] + "\n\n…[meio omitido]…\n\n" + text[-tail:]


def build_context(
    map_data: dict[str, Any],
    ranked_files: list[dict[str, Any]],
    query: str,
    *,
    max_tokens: int = 4500,
) -> str:
    """Contexto para o LLM — mapa + arquivos prioritários, sem descarte cego."""
    budget = _budget_chars(max_tokens)
    parts: list[str] = []

    frameworks = ", ".join(map_data.get("frameworks") or [])
    langs = map_data.get("languages") or {}
    parts.append(
        "[PROJECT ANALYZER — contexto selecionado para esta pergunta]\n"
        f"Frameworks: {frameworks}\n"
        f"Linguagens: {langs}\n"
        f"Arquivos indexados: {map_data.get('file_count', 0)}\n"
        f"Pergunta: {query.strip()[:300]}\n"
    )

    # mapa resumido (paths only)
    all_paths = [f["path"] for f in (map_data.get("files") or [])[:80]]
    parts.append("Mapa (amostra de paths):\n" + "\n".join(f"- {p}" for p in all_paths[:60]))

    used = sum(len(p) for p in parts)
    remaining = budget - used - 200

    # distribuir entre top files
    selected = ranked_files[:12]
    if not selected:
        parts.append(
            "\n(Nenhum arquivo fortemente relacionado; use o mapa e peça paths específicos.)"
        )
        return "\n\n".join(parts)

    per_file = max(800, remaining // max(len(selected), 1))
    parts.append("\nArquivos relevantes (conteúdo):\n")

    for item in selected:
        path = item["path"]
        text = item.get("text") or item.get("preview") or ""
        chunk = _smart_clip(text, per_file)
        block = f"### FILE: {path}\n```\n{chunk}\n```\n"
        if used + len(block) > budget:
            # ainda tenta versão menor
            chunk = _smart_clip(text, 600)
            block = f"### FILE: {path}\n```\n{chunk}\n```\n"
            if used + len(block) > budget:
                parts.append(
                    f"(Orçamento desta chamada esgotado; há mais arquivos no índice. "
                    f"Peça paths concretos se precisar.)"
                )
                break
        parts.append(block)
        used += len(block)

    parts.append(
        "\nInstruções: analise com base neste contexto. "
        "Se faltar um arquivo crítico listado no mapa, diga o path e o que precisa dele. "
        "Não invente código que não esteja aqui."
    )
    return "\n".join(parts)
