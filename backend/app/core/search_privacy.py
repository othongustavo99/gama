"""Sanitização de consultas enviadas a mecanismos de busca externos.

O objetivo é reduzir a exposição acidental de código colado, credenciais e dados
pessoais. Não é um classificador perfeito nem uma garantia de anonimato; a busca
externa continua enviando a consulta sanitizada ao provedor escolhido.
"""
from __future__ import annotations

import re

_CODE_BLOCK = re.compile(r"```[\s\S]*?```", re.MULTILINE)
_INLINE_CODE = re.compile(r"`[^`\n]{1,4000}`")
_PRIVATE_KEY = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    re.IGNORECASE,
)
_SECRET_ASSIGNMENT = re.compile(
    r"(?i)\b(?:[A-Z0-9]+[_-])*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key|password|passwd|senha|token|authorization)\b\s*[:=]\s*(?:Bearer\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"
)
_BEARER = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{8,}={0,2}")
_API_TOKEN = re.compile(
    r"\b(?:sk-(?:or-v1-)?[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{12,})\b"
)
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")
_EMAIL = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE)
_CPF = re.compile(r"(?<!\d)\d{3}\.?\d{3}\.?\d{3}-?\d{2}(?!\d)")
_CNPJ = re.compile(r"(?<!\d)\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}(?!\d)")
_PHONE = re.compile(r"(?<!\w)(?:\+?55[\s.-]?)?\(?\d{2}\)?[\s.-]?9?\d{4}[\s.-]?\d{4}(?!\w)")
_URL_SECRET_PARAM = re.compile(
    r"(?i)([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|signature|auth|key)=)[^&#\s]+"
)
_URL_USERINFO = re.compile(r"(https?://)[^/@\s]+:[^/@\s]+@", re.IGNORECASE)
_SECRET_MARK = "[credencial-removida]"


def sanitize_search_query(query: str, *, max_chars: int = 220) -> str:
    """Remove trechos de código e substitui credenciais/dados pessoais comuns."""
    text = str(query or "").strip()
    if not text:
        return ""

    # Remover código é mais seguro que tentar extrair o que é público de um bloco.
    text = _PRIVATE_KEY.sub(" [chave privada removida] ", text)
    text = _CODE_BLOCK.sub(" [bloco de código omitido] ", text)
    text = _INLINE_CODE.sub(" [trecho de código omitido] ", text)
    text = _URL_SECRET_PARAM.sub(lambda m: f"{m.group(1)}{_SECRET_MARK}", text)
    text = _SECRET_ASSIGNMENT.sub(lambda m: f"{m.group(0).split('=', 1)[0].split(':', 1)[0]}={_SECRET_MARK}", text)
    text = _BEARER.sub(f"Bearer {_SECRET_MARK}", text)
    text = _API_TOKEN.sub(_SECRET_MARK, text)
    text = _JWT.sub(_SECRET_MARK, text)
    text = _URL_USERINFO.sub(r"\1[credenciais-removidas]@", text)
    text = _EMAIL.sub("[e-mail removido]", text)
    text = _CPF.sub("[documento removido]", text)
    text = _CNPJ.sub("[documento removido]", text)
    text = _PHONE.sub("[telefone removido]", text)

    # Remove instruções conversacionais comuns para enviar só o tópico necessário.
    text = re.sub(
        r"^(?:por favor[, ]*|pesquise(?: na internet)?|pesquisar|busque|buscar|procure|google|me diga|quero saber|poderia pesquisar)\s*[:,]?\s*",
        "",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(r"\s+", " ", text).strip(" \t\r\n:;,.-")
    if len(text) > max_chars:
        text = text[:max_chars].rsplit(" ", 1)[0].strip()
    # Não dispara uma consulta formada só por marcadores de remoção.
    marker_only = re.sub(
        r"\[(?:bloco de código omitido|trecho de código omitido|credencial[- ]removida|e-mail removido|documento removido|telefone removido|chave privada removida)\]",
        "",
        text,
        flags=re.IGNORECASE,
    )
    if not re.search(r"[A-Za-zÀ-ÿ0-9]", marker_only):
        return ""
    return text
