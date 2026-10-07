"""Talk Skill — camada transversal de conversação natural da Gama.

Não substitui a personalidade principal nem outras skills.
Controla *como* a Gama conversa (naturalidade, voz, opinião, ritmo).
"""

from .pipeline import build_talk_layer, detect_talk_mode

__all__ = ["build_talk_layer", "detect_talk_mode"]
