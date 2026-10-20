"""Relevance engine: prioriza o que realmente importa para a pergunta."""

from __future__ import annotations

from typing import Any


def rank_for_query(
    ranked: list[dict[str, Any]],
    query: str,
    *,
    level: str = "targeted",
) -> list[dict[str, Any]]:
    """Reordena e corta conforme o nível de análise.

    quick     → poucos arquivos (mapa + 3–5)
    targeted  → foco no fluxo (8–14)
    deep      → mais amplo (18–25) ainda sem jogar o projeto inteiro

    Arquivos com forced=True (mencionados explicitamente) nunca são cortados.
    """
    if not ranked:
        return []

    q = (query or "").lower()
    for r in ranked:
        if r.get("forced"):
            r["score"] = max(float(r.get("score") or 0), 999.0)
            continue
        pl = r.get("path", "").lower()
        for tok in q.split():
            if len(tok) > 3 and tok in pl:
                r["score"] = float(r.get("score") or 0) + 2.0
        if r.get("via_dependency"):
            r["score"] = float(r.get("score") or 0) + 1.5

    ranked = sorted(
        ranked,
        key=lambda x: (0 if x.get("forced") else 1, -float(x.get("score") or 0)),
    )

    limits = {"quick": 5, "targeted": 14, "deep": 24}
    k = limits.get(level, 14)

    forced = [r for r in ranked if r.get("forced")]
    others = [r for r in ranked if not r.get("forced")]
    # sempre inclui todos os forced + completa até o limite
    out = forced + others[: max(0, k - len(forced))]
    return out


def suggest_followup_paths(
    ranked: list[dict[str, Any]],
    all_files: list[dict[str, Any]],
    query: str,
) -> list[str]:
    """Sugere paths extras se o contexto inicial parecer incompleto (para 2ª etapa)."""
    have = {r["path"] for r in ranked}
    suggestions: list[str] = []
    q_terms = [t for t in query.lower().split() if len(t) > 3]
    for f in all_files:
        p = f["path"]
        if p in have:
            continue
        pl = p.lower()
        if any(t in pl for t in q_terms):
            suggestions.append(p)
        if len(suggestions) >= 8:
            break
    return suggestions
