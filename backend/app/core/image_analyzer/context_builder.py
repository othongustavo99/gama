"""Formata o resultado visual em contexto compacto para o modelo principal."""

from __future__ import annotations

import json
from typing import Any


def compact_visual_context(
    *,
    query: str,
    prepared: list[dict[str, Any]],
    analysis: dict[str, Any],
) -> str:
    payload = {
        "image_analyzer": "Image Analyzer",
        "user_question": query.strip()[:1200],
        "images": prepared,
        "analysis": analysis,
    }
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))

    # Proteção adicional: o contexto textual não deve virar um segundo
    # "buraco negro" de tokens. O modelo visual já fez a leitura pesada.
    max_chars = 12000
    if len(raw) <= max_chars:
        return (
            "[IMAGE ANALYZER — contexto visual otimizado]\n"
            "Use este contexto como evidência da imagem. Não invente detalhes "
            "que o analisador não identificou.\n"
            + raw
        )

    trimmed = dict(payload)
    analysis_copy = dict(analysis)
    for key in ("ocr", "visual_summary", "details", "regions"):
        value = analysis_copy.get(key)
        if isinstance(value, str) and len(value) > 2500:
            analysis_copy[key] = value[:2500] + "…[resumo cortado]"
    trimmed["analysis"] = analysis_copy
    raw = json.dumps(trimmed, ensure_ascii=False, separators=(",", ":"))
    return (
        "[IMAGE ANALYZER — contexto visual otimizado]\n"
        "Use este contexto como evidência da imagem.\n" + raw[:max_chars]
    )
