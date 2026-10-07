"""Monta contexto dinamicamente — orçamento flexível, não hard-limit cego de 8k."""

from __future__ import annotations

from typing import Any


def _budget_chars(max_tokens: int) -> int:
    # ~3.2 chars/token conservador para código
    return max(2000, int(max_tokens * 3.2))


def _smart_clip(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
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
    level: str = "targeted",
    source_label: str = "Code Analyzer",
    followup_paths: list[str] | None = None,
) -> str:
    """Contexto para o LLM — mapa + arquivos prioritários + dica de 2ª etapa."""
    budget = _budget_chars(max_tokens)
    parts: list[str] = []

    frameworks = ", ".join(map_data.get("frameworks") or [])
    langs = map_data.get("languages") or {}
    parts.append(
        f"[{source_label} — contexto selecionado | nível: {level}]\n"
        f"Frameworks: {frameworks}\n"
        f"Linguagens: {langs}\n"
        f"Arquivos indexados: {map_data.get('file_count', 0)}\n"
        f"Pergunta: {query.strip()[:300]}\n"
        "Instrução interna: use só o necessário. Se faltar arquivo, peça paths "
        "específicos ou marque [need_more:path1,path2] para segunda etapa.\n"
    )

    all_paths = [f["path"] for f in (map_data.get("files") or [])[:100]]
    parts.append("Mapa (amostra de paths):\n" + "\n".join(f"- {p}" for p in all_paths[:70]))

    used = sum(len(p) for p in parts)
    remaining = budget - used - 300

    selected = ranked_files
    if not selected:
        parts.append(
            "\n(Nenhum arquivo fortemente relacionado; use o mapa e peça paths específicos.)"
        )
        return "\n".join(parts)

    per_file = max(800, remaining // max(len(selected), 1))
    parts.append("\n--- Arquivos relevantes ---")
    for item in selected:
        path = item.get("path", "?")
        text = item.get("text") or item.get("preview") or ""
        tag = " (dep)" if item.get("via_dependency") else ""
        score = item.get("score")
        header = f"\n### {path}{tag}"
        if score is not None:
            header += f"  [score={score:.1f}]"
        clip = _smart_clip(text, per_file)
        block = f"{header}\n```\n{clip}\n```"
        if used + len(block) > budget:
            # ainda cabe um resumo menor
            clip = _smart_clip(text, max(400, budget - used - 80))
            block = f"{header}\n```\n{clip}\n```"
            if used + len(block) > budget:
                break
        parts.append(block)
        used += len(block)

    if followup_paths:
        parts.append(
            "\n[Possíveis paths para segunda etapa se faltar contexto]:\n"
            + "\n".join(f"- {p}" for p in followup_paths[:8])
        )

    return "\n".join(parts)
