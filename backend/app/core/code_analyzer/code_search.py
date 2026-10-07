"""Busca por termos, símbolos, conceitos e fluxos — não só literal."""

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
}


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
    for k, vals in _EXPAND.items():
        if k in q:
            for v in vals:
                if v not in terms:
                    terms.append(v)
    # códigos HTTP comuns
    for code in re.findall(r"\b([45]\d{2})\b", q):
        if code not in terms:
            terms.append(code)
    return terms[:50] or ["main", "app", "config"]


def score_file(
    path: str,
    text: str,
    terms: list[str],
    important: bool,
    symbols: list[str] | None = None,
) -> float:
    pl = path.lower()
    tl = text.lower()
    score = 0.0
    for t in terms:
        if t in pl:
            score += 4.0
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
    scored: list[dict[str, Any]] = []
    symbol_index = symbol_index or {}

    # sempre prioriza configs importantes
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

    candidates = list(file_metas)
    # boost paths that match terms in name
    for meta in candidates:
        path = meta["path"]
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
