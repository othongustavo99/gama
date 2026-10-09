"""Detecta a origem do código: GitHub URL, ZIP marker, PDF, código inline."""

from __future__ import annotations

import re
from typing import Optional
from urllib.parse import urlparse

_GITHUB_RE = re.compile(
    r"https?://(?:www\.)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?(?:/tree/([A-Za-z0-9_.\-/]+))?(?:/|$|\s|#|\?)",
    re.I,
)
_PROJECT_ID_RE = re.compile(r"\[project_id:([a-zA-Z0-9_\-]{6,32})\]")
_PDF_ID_RE = re.compile(r"\[pdf_id:([a-zA-Z0-9_\-]{6,32})\]")
# bloco de código markdown ou trecho longo de código
_CODE_FENCE_RE = re.compile(r"```[\w]*\n([\s\S]{80,}?)```")
_INLINE_CODE_HINT = re.compile(
    r"(?:def |class |function |import |package |void |Future<|public |private |fn |func )",
)


def parse_github_url(text: str) -> Optional[dict[str, str]]:
    m = _GITHUB_RE.search(text or "")
    if not m:
        return None
    owner, repo, branch_path = m.group(1), m.group(2), m.group(3)
    branch = "main"
    if branch_path:
        # /tree/main/lib/... → branch=main
        parts = branch_path.strip("/").split("/")
        branch = parts[0] if parts else "main"
    return {
        "owner": owner,
        "repo": repo.rstrip(".git"),
        "branch": branch,
        "url": f"https://github.com/{owner}/{repo}",
    }


def extract_project_id(text: str) -> Optional[str]:
    m = _PROJECT_ID_RE.search(text or "")
    return m.group(1) if m else None


def extract_pdf_id(text: str) -> Optional[str]:
    m = _PDF_ID_RE.search(text or "")
    return m.group(1) if m else None


def extract_inline_code(text: str) -> Optional[str]:
    """Se a mensagem é majoritariamente código, retorna o trecho."""
    if not text or len(text) < 100:
        return None
    fences = _CODE_FENCE_RE.findall(text)
    if fences:
        joined = "\n\n".join(fences)
        if len(joined) >= 80:
            return joined
    # texto cru com densidade de código
    if _INLINE_CODE_HINT.search(text) and text.count("\n") >= 5:
        # evita misturar com prosa longa
        if len(text) < 25_000:
            return text
    return None


def detect_level(query: str) -> str:
    q = (query or "").lower()
    deep_hints = [
        "arquitetura inteira",
        "arquitetura completa",
        "revisão completa",
        "analise o projeto",
        "analise completa",
        "análise completa",
        "todo o projeto",
        "code review",
        "revisão de código",
        "problemas no projeto",
        "deep",
        "full analysis",
        # pedido de conteúdo integral de arquivo(s)
        "conteúdo completo",
        "conteudo completo",
        "texto integral",
        "texto completo",
        "texto literal",
        "arquivo completo",
        "linha por linha",
        "na íntegra",
        "na integra",
        "completo e literal",
        "o que tem dentro",
        "me diga exatamente",
    ]
    quick_hints = [
        "que linguagem",
        "qual framework",
        "estrutura do projeto",
        "resumo do projeto",
        "o que é esse projeto",
        "linguagens usadas",
        "dependências",
    ]
    for h in deep_hints:
        if h in q:
            return "deep"
    for h in quick_hints:
        if h in q:
            return "quick"
    return "targeted"
