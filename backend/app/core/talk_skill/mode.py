"""Detecta Conversational Talk vs Focused Talk a partir da mensagem e do contexto."""

from __future__ import annotations

import re
from typing import List, Optional

# pistas de tarefa técnica / focada
_FOCUSED = re.compile(
    r"(?i)\b("
    r"corrija|corrige|fix|bug|erro|exception|stack\s*trace|"
    r"implemente|implementa|refatore|refatora|crie\s+(uma?\s+)?(função|classe|endpoint|tela|widget)|"
    r"código|codigo|arquivo|path|import|export|api|endpoint|json|sql|"
    r"analis[ea]|debug|teste|testes|build|deploy|compile|"
    r"pdf|zip|github|reposit[oó]rio|projeto|"
    r"explique\s+o\s+c[oó]digo|como\s+funciona\s+(esse|este|o)\s+|"
    r"por\s+que\s+(d[aá]|retorna|falha)|why\s+does|"
    r"write\s+code|fix\s+this|implement|refactor"
    r")\b"
)

# pistas de conversa casual / opinião
_CASUAL = re.compile(
    r"(?i)\b("
    r"o\s+que\s+voc[eê]\s+acha|na\s+sua\s+opini[aã]o|concorda|"
    r"e\s+a[ií]\??|beleza|valeu|obrigad[oa]|kk+|haha|rsrs|"
    r"tudo\s+bem|como\s+voc[eê]\s+est[aá]|bom\s+dia|boa\s+noite|boa\s+tarde|"
    r"conta\s+mais|me\s+conta|interessante|curioso|curiosa|"
    r"discordo|concordo|s[eé]rio\??|n[aã]o\s+sei|"
    r"what\s+do\s+you\s+think|your\s+opinion|lol|haha"
    r")\b"
)

# mensagens muito curtas e sem carga técnica → conversacional
_SHORT_CASUAL = re.compile(
    r"(?i)^\s*(oi|ol[aá]|eae|e\s*a[ií]|ok|blz|sim|n[aã]o|talvez|hm+|ahh+|entendi|certo|pode|manda|"
    r"continua|e\s+depois\??|e\s+se\??|por\s+qu[eê]\??|como\s+assim\??)\s*[?.!]?\s*$"
)


def detect_talk_mode(
    last_user: str,
    *,
    messages: Optional[List[dict]] = None,
    voice_mode: bool = False,
    has_code_context: bool = False,
    has_project_context: bool = False,
    has_web_block: bool = False,
) -> str:
    """Retorna 'conversational' | 'focused'."""
    text = (last_user or "").strip()

    if has_code_context or has_project_context:
        # skill técnica ativa → focused, a menos que seja só um comentário curto
        if text and _SHORT_CASUAL.match(text) and not _FOCUSED.search(text):
            return "conversational"
        return "focused"

    if has_web_block and _FOCUSED.search(text):
        return "focused"

    if not text:
        return "conversational" if voice_mode else "focused"

    if _FOCUSED.search(text):
        return "focused"

    if _CASUAL.search(text) or _SHORT_CASUAL.match(text):
        return "conversational"

    # código colado / blocos markdown longos
    if "```" in text or text.count("\n") >= 8:
        if any(
            k in text.lower()
            for k in ("def ", "class ", "function ", "import ", "void ", "final ", "widget")
        ):
            return "focused"

    # histórico recente com muita técnica
    if messages:
        recent = " ".join(
            (m.get("content") or "")[:200]
            for m in messages[-6:]
            if m.get("role") == "user"
        ).lower()
        tech_hits = sum(
            1
            for k in ("erro", "bug", "código", "codigo", "arquivo", "api", "fix", "implement")
            if k in recent
        )
        if tech_hits >= 2 and len(text) > 40:
            return "focused"

    # default: voz tende a conversacional; texto longo sem pistas → focused leve
    if voice_mode and len(text) < 280:
        return "conversational"

    if len(text) < 60 and not _FOCUSED.search(text):
        return "conversational"

    return "focused"
