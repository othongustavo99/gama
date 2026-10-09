"""Monta contexto dinamicamente — orçamento flexível, não hard-limit cego de 8k.

Quando o usuário pede o conteúdo completo/literal de um arquivo específico
(forced), esse arquivo NÃO é truncado e recebe prioridade no orçamento.
"""

from __future__ import annotations

import re
from typing import Any

# intenção de conteúdo integral
_FULL_CONTENT_RE = re.compile(
    r"(conte[uú]do\s+completo|texto\s+(?:integral|completo|literal)|"
    r"arquivo\s+completo|linha\s+por\s+linha|na\s*[ií]ntegra|"
    r"completo\s+e\s+literal|sem\s+cortar|sem\s+truncar|"
    r"full\s+content|entire\s+file|whole\s+file|"
    r"me\s+diga\s+(?:exatamente\s+)?o\s+que\s+tem|"
    r"o\s+que\s+tem\s+dentro|mostra(?:r)?\s+o\s+conte[uú]do|"
    r"leia\s+o\s+arquivo|cole\s+o\s+arquivo)",
    re.I,
)


def _wants_full_content(query: str) -> bool:
    q = query or ""
    if _FULL_CONTENT_RE.search(q):
        return True
    # [need_more:...] implica pedido de conteúdo integral desses paths
    if "[need_more:" in q.lower():
        return True
    if any(
        k in q.lower()
        for k in (
            "códigos completos",
            "codigos completos",
            "código completo",
            "codigo completo",
            "prontos para substituir",
        )
    ):
        return True
    return False


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
    """Contexto para o LLM — mapa + arquivos prioritários.

    Arquivos com forced=True (mencionados na pergunta) têm prioridade.
    Se a pergunta pede conteúdo completo, esses arquivos NÃO são truncados
    (até um teto alto de segurança).
    """
    full_intent = _wants_full_content(query)
    forced = [r for r in ranked_files if r.get("forced")]
    others = [r for r in ranked_files if not r.get("forced")]

    # pedido de arquivo completo → orçamento bem maior só para esses arquivos
    if full_intent and forced:
        # 1 arquivo ~12k; vários arquivos completos escalam
        max_tokens = max(max_tokens, min(32000, 8000 + 3500 * len(forced)))
    elif forced and level != "quick":
        max_tokens = max(max_tokens, min(16000, 5000 + 2000 * len(forced)))

    budget = _budget_chars(max_tokens)
    parts: list[str] = []

    frameworks = ", ".join(map_data.get("frameworks") or [])
    langs = map_data.get("languages") or {}

    if full_intent and forced:
        paths = ", ".join(r.get("path", "?") for r in forced)
        parts.append(
            f"[{source_label} — CONTEÚDO COMPLETO solicitado | nível: {level}]\n"
            f"Frameworks: {frameworks}\n"
            f"Arquivos pedidos (conteúdo integral abaixo): {paths}\n"
            f"Pergunta: {query.strip()[:300]}\n"
            "Instrução interna: os arquivos abaixo foram carregados NA ÍNTEGRA. "
            "Você TEM o texto completo. Reproduza ou analise com base nele. "
            "NÃO diga que o conteúdo está parcial/truncado. "
            "NÃO peça para o usuário colar o arquivo de novo.\n"
        )
    else:
        parts.append(
            f"[{source_label} — contexto selecionado | nível: {level}]\n"
            f"Frameworks: {frameworks}\n"
            f"Linguagens: {langs}\n"
            f"Arquivos indexados: {map_data.get('file_count', 0)}\n"
            f"Pergunta: {query.strip()[:300]}\n"
            "Instrução interna: use só o necessário. Se faltar arquivo, peça paths "
            "específicos ou marque [need_more:path1,path2] para segunda etapa.\n"
        )

    # mapa de paths só quando não é foco em 1–2 arquivos completos
    if not (full_intent and forced and len(forced) <= 3):
        all_paths = [f["path"] for f in (map_data.get("files") or [])[:100]]
        parts.append(
            "Mapa (amostra de paths):\n" + "\n".join(f"- {p}" for p in all_paths[:70])
        )

    used = sum(len(p) for p in parts)
    remaining = max(500, budget - used - 200)

    selected = ranked_files
    if not selected:
        parts.append(
            "\n(Nenhum arquivo fortemente relacionado; use o mapa e peça paths específicos.)"
        )
        return "\n".join(parts)

    # teto por arquivo:
    # - forced + full intent → quase sem corte (até 200k, já limitado na leitura)
    # - forced normal → fatia generosa
    # - demais → divide o restante
    FULL_FILE_CAP = 200_000
    FORCED_CAP = 80_000

    n_forced = max(len(forced), 1)
    n_others = max(len(others), 1)

    if full_intent and forced:
        # quase todo o orçamento para os forced
        forced_budget = min(FULL_FILE_CAP, max(remaining - 500, remaining // n_forced))
        other_budget = max(400, (remaining - forced_budget * len(forced)) // n_others) if others else 0
    elif forced:
        forced_budget = min(FORCED_CAP, max(3000, remaining // (n_forced + max(n_others // 2, 1))))
        other_budget = max(600, (remaining - forced_budget * len(forced)) // n_others) if others else 0
    else:
        forced_budget = 0
        other_budget = max(800, remaining // max(len(selected), 1))

    parts.append("\n--- Arquivos relevantes ---")

    def _append_file(item: dict[str, Any], cap: int, no_clip: bool = False) -> bool:
        nonlocal used
        path = item.get("path", "?")
        text = item.get("text") or item.get("preview") or ""
        if not text:
            return True  # nada a acrescentar, continua
        tag = " (dep)" if item.get("via_dependency") else ""
        if item.get("forced"):
            tag += " [arquivo pedido]"
        score = item.get("score")
        header = f"\n### {path}{tag}"
        if score is not None:
            header += f"  [score={score:.1f}]"

        if no_clip or len(text) <= cap:
            body = text
            note = ""
        else:
            body = _smart_clip(text, cap)
            note = f"\n…[arquivo tem {len(text)} chars; trecho enviado={len(body)}]"

        block = f"{header}\n```\n{body}\n```{note}"
        if used + len(block) > budget and not (item.get("forced") and full_intent):
            # tenta caber um resumo menor
            smaller = max(400, budget - used - 100)
            if smaller < 300:
                return False
            body = _smart_clip(text, smaller)
            block = f"{header}\n```\n{body}\n```"
            if used + len(block) > budget:
                return False
        # forced + full: estoura um pouco o budget se necessário (modelo aguenta)
        parts.append(block)
        used += len(block)
        return True

    # 1) arquivos forçados primeiro, sem clip se full intent
    for item in forced:
        ok = _append_file(
            item,
            cap=forced_budget if forced_budget else FORCED_CAP,
            no_clip=bool(full_intent),
        )
        if not ok and not full_intent:
            break

    # 2) demais arquivos
    for item in others:
        if used >= budget - 200:
            break
        ok = _append_file(item, cap=other_budget if other_budget else 800, no_clip=False)
        if not ok:
            break

    if followup_paths and not (full_intent and forced):
        parts.append(
            "\n[Possíveis paths para segunda etapa se faltar contexto]:\n"
            + "\n".join(f"- {p}" for p in followup_paths[:8])
        )

    return "\n".join(parts)
