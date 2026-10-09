"""Busca por termos, símbolos, conceitos e fluxos — não só literal.

Também detecta menções explícitas a arquivos (ex: "o que tem em context.py",
"contexto.py", "main.dart") e força o carregamento do conteúdo.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

# expansões semânticas por domínio (PT + EN)
_EXPAND = {
    "login": [
        "login", "auth", "signin", "sign_in", "sign-in", "token", "session",
        "oauth", "google", "firebase", "user", "password", "credential",
        "authenticate", "authorization", "bearer", "jwt",
    ],
    "auth": [
        "auth", "login", "token", "jwt", "oauth", "session", "firebase",
        "google_sign", "interceptor", "authorization", "bearer",
    ],
    "memoria": ["memory", "memoria", "fact", "prefs", "shared_preferences", "user_id"],
    "memory": ["memory", "fact", "prefs", "shared_preferences"],
    "chat": ["chat", "message", "stream", "conversation", "ollama", "llm", "groq"],
    "api": ["api", "http", "dio", "endpoint", "route", "fastapi", "request", "client"],
    "erro": ["error", "exception", "fail", "bug", "crash", "stack", "401", "403", "500"],
    "error": ["error", "exception", "fail", "bug", "crash", "401", "403"],
    "ui": ["widget", "screen", "build", "scaffold", "drawer", "page"],
    "banco": ["database", "sqlite", "hive", "firestore", "sql"],
    "llm": ["llm", "openai", "groq", "ollama", "chat", "completion", "model", "prompt"],
    "ia": ["llm", "ai", "openai", "groq", "ollama", "chat", "prompt", "model"],
    "envio": ["send", "post", "request", "stream", "chat", "message", "api"],
    "mensagem": ["message", "chat", "send", "stream", "content"],
    "contexto": ["context", "contexto", "context_manager", "contextmanager"],
    "context": ["context", "contexto", "context_manager", "contextmanager"],
}

# variantes PT ↔ EN comuns em nomes de arquivo
_STEM_ALIASES: dict[str, set[str]] = {
    "contexto": {"context", "contexto"},
    "context": {"context", "contexto"},
    "memoria": {"memory", "memoria"},
    "memory": {"memory", "memoria"},
    "configuracao": {"config", "configuration", "configuracao", "settings"},
    "config": {"config", "configuration", "configuracao", "settings"},
    "autenticacao": {"auth", "authentication", "autenticacao", "login"},
    "auth": {"auth", "authentication", "autenticacao", "login"},
    "mensagem": {"message", "mensagem", "messages"},
    "message": {"message", "mensagem", "messages"},
    "conversa": {"conversation", "conversa", "chat"},
    "conversation": {"conversation", "conversa", "chat"},
    "utilitario": {"util", "utils", "utility", "utilitario", "helpers"},
    "utils": {"util", "utils", "utility", "utilitario", "helpers"},
}

# regex: nome de arquivo com extensão comum de código
_FILE_MENTION_RE = re.compile(
    r"""
    (?:^|[\s`'\"(\[{/\\])          # início ou separador
    (
        [\w\-./]+?                 # path ou stem
        \.
        (?:dart|py|js|ts|tsx|jsx|java|kt|kts|go|rs|swift|cs|rb|php|
           c|cpp|h|hpp|json|yaml|yml|toml|md|txt|xml|html|css|sql|
           gradle|sh|bat|properties|cfg|ini)
    )
    (?:$|[\s`'\"\)\]},:;!?])       # fim ou separador
    """,
    re.I | re.X,
)

# menções sem extensão: "o arquivo context", "dentro de contexto"
_BARE_NAME_RE = re.compile(
    r"""
    (?:arquivo|file|modulo|módulo|classe|class|dentro\s+de|conteudo\s+de|conteúdo\s+de|
       o\s+que\s+tem\s+(?:em|no|na|dentro)|leia|mostrar|mostra|abre|abrir|analise|analisa|analisar)
    \s+
    [`'"]?
    ([a-zA-Z_][\w\-]{2,40})
    [`'"]?
    """,
    re.I | re.X,
)


def expand_query(query: str) -> list[str]:
    q = (query or "").lower()
    terms: list[str] = []
    for t in re.findall(r"[a-zA-ZÀ-ÿ_][\wÀ-ÿ]{2,}", q):
        tl = t.lower()
        if tl not in terms:
            terms.append(tl)
        for k, vals in _EXPAND.items():
            if k in tl or tl in k:
                for v in vals:
                    if v not in terms:
                        terms.append(v)
        # aliases de stem
        if tl in _STEM_ALIASES:
            for v in _STEM_ALIASES[tl]:
                if v not in terms:
                    terms.append(v)
    for k, vals in _EXPAND.items():
        if k in q:
            for v in vals:
                if v not in terms:
                    terms.append(v)
    for code in re.findall(r"\b([45]\d{2})\b", q):
        if code not in terms:
            terms.append(code)
    return terms[:50] or ["main", "app", "config"]


def extract_mentioned_filenames(query: str) -> list[str]:
    """Extrai nomes de arquivo (com ou sem path) mencionados na pergunta.

    Exemplos que capturam:
      - "contexto.py"
      - "backend/app/core/context.py"
      - "o que tem dentro de context.py"
      - "leia o arquivo context"
    """
    q = query or ""
    found: list[str] = []

    for m in _FILE_MENTION_RE.finditer(q):
        name = m.group(1).strip().lstrip("./").replace("\\", "/")
        if name and name not in found:
            found.append(name)

    for m in _BARE_NAME_RE.finditer(q):
        stem = m.group(1).strip().lower()
        if stem and len(stem) >= 3 and stem not in found:
            found.append(stem)

    return found[:12]


def _stem_matches(query_name: str, file_basename: str) -> bool:
    """Match flexível: context.py ↔ contexto.py, context ↔ context.py, etc."""
    q = query_name.lower().strip()
    b = file_basename.lower().strip()
    if not q or not b:
        return False
    if q == b:
        return True
    # path relativo completo
    if q.endswith("/" + b) or q.endswith("\\" + b):
        return True
    q_stem = Path(q).stem.lower()
    b_stem = Path(b).stem.lower()
    if q_stem == b_stem:
        return True
    # aliases PT/EN
    aliases = _STEM_ALIASES.get(q_stem) or _STEM_ALIASES.get(b_stem) or set()
    if q_stem in aliases and b_stem in aliases:
        return True
    if q_stem in aliases and b_stem == q_stem:
        return True
    # substring razoável (ex: "context" em "context_manager.dart")
    if len(q_stem) >= 4 and (q_stem in b_stem or b_stem in q_stem):
        return True
    return False


def find_matching_paths(
    file_metas: list[dict[str, Any]],
    mentioned: list[str],
) -> list[str]:
    """Retorna paths do índice que batem com nomes mencionados na query."""
    if not mentioned:
        return []
    hits: list[str] = []
    for meta in file_metas:
        path = meta.get("path") or ""
        base = Path(path).name
        for m in mentioned:
            # match por path completo ou basename
            m_norm = m.replace("\\", "/").lstrip("./")
            if (
                path.lower() == m_norm.lower()
                or path.lower().endswith("/" + m_norm.lower())
                or _stem_matches(m_norm, base)
                or _stem_matches(m_norm, path)
            ):
                if path not in hits:
                    hits.append(path)
                break
    return hits


def score_file(
    path: str,
    text: str,
    terms: list[str],
    important: bool,
    symbols: list[str] | None = None,
    *,
    forced: bool = False,
) -> float:
    if forced:
        return 999.0
    pl = path.lower()
    tl = text.lower()
    score = 0.0
    basename = Path(path).name.lower()
    for t in terms:
        if t in pl:
            score += 4.0
        if t in basename or basename.startswith(t):
            score += 6.0  # boost forte quando o nome do arquivo aparece na query
        c = tl.count(t)
        if c:
            score += min(c, 12) * 1.2
    if symbols:
        for s in symbols:
            sl = s.lower().removeprefix("imp:")
            for t in terms:
                if t in sl or sl in t:
                    score += 3.0
                    break
    if important:
        score += 2.5
    if "/test" in pl or "_test." in pl:
        score *= 0.7
    if pl.endswith(".md"):
        score *= 0.85
    return score


def search_files(
    root: Path,
    file_metas: list[dict[str, Any]],
    query: str,
    *,
    top_k: int = 20,
    symbol_index: dict[str, list[str]] | None = None,
    max_read: int = 100,
) -> list[dict[str, Any]]:
    terms = expand_query(query)
    mentioned = extract_mentioned_filenames(query)
    forced_paths = set(find_matching_paths(file_metas, mentioned))
    scored: list[dict[str, Any]] = []
    symbol_index = symbol_index or {}
    seen: set[str] = set()

    priority_names = {
        "pubspec.yaml",
        "package.json",
        "requirements.txt",
        "pyproject.toml",
        "main.dart",
        "main.py",
        "app.py",
        "build.gradle",
        "go.mod",
        "cargo.toml",
    }

    # 1) Arquivos explicitamente mencionados — sempre incluir com conteúdo
    for meta in file_metas:
        path = meta["path"]
        if path not in forced_paths:
            continue
        p = root / path
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        if len(text) > 200_000:
            text = text[:200_000]
        syms = symbol_index.get(path) or []
        scored.append(
            {
                **meta,
                "score": 999.0,
                "preview": text[:500],
                "text": text,
                "symbols": syms,
                "forced": True,
            }
        )
        seen.add(path)

    # 2) Ranking normal dos demais
    for meta in file_metas:
        path = meta["path"]
        if path in seen:
            continue
        p = root / path
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        if len(text) > 200_000:
            text = text[:200_000]
        syms = symbol_index.get(path) or []
        sc = score_file(path, text, terms, bool(meta.get("important")), syms)
        name_l = Path(path).name.lower()
        if name_l in priority_names:
            sc += 5.0
        if sc <= 0 and not meta.get("important"):
            continue
        scored.append(
            {
                **meta,
                "score": sc,
                "preview": text[:500],
                "text": text,
                "symbols": syms,
            }
        )
        seen.add(path)

    scored.sort(key=lambda x: -x["score"])
    return scored[:top_k]


def search_by_symbol(
    symbol_index: dict[str, list[str]],
    name: str,
) -> list[str]:
    """Paths que definem ou importam o símbolo."""
    name_l = name.lower()
    hits: list[str] = []
    for path, syms in symbol_index.items():
        for s in syms:
            if s.lower().removeprefix("imp:") == name_l or name_l in s.lower():
                hits.append(path)
                break
    return hits
