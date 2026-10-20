"""Orquestra a Talk Skill: detecta modo e monta a camada de estilo."""

from __future__ import annotations

from typing import List, Optional

from .mode import detect_talk_mode
from .prompts import (
    CONVERSATIONAL_LAYER,
    FOCUSED_LAYER,
    SHARED_RULES,
    VOICE_LAYER,
)


def build_talk_layer(
    last_user: str = "",
    *,
    messages: Optional[List[dict]] = None,
    voice_mode: bool = False,
    has_code_context: bool = False,
    has_project_context: bool = False,
    has_web_block: bool = False,
    force_mode: Optional[str] = None,
) -> tuple[str, str]:
    """Retorna (modo, texto da camada Talk para o system prompt).

    modo: 'conversational' | 'focused'
    """
    mode = force_mode or detect_talk_mode(
        last_user,
        messages=messages,
        voice_mode=voice_mode,
        has_code_context=has_code_context,
        has_project_context=has_project_context,
        has_web_block=has_web_block,
    )
    if mode not in ("conversational", "focused"):
        mode = "focused"

    parts: list[str] = [SHARED_RULES]
    if mode == "conversational":
        parts.append(CONVERSATIONAL_LAYER)
    else:
        parts.append(FOCUSED_LAYER)

    if voice_mode:
        parts.append(VOICE_LAYER)

    return mode, "\n\n".join(parts)


# re-export para conveniência
__all__ = ["build_talk_layer", "detect_talk_mode"]
