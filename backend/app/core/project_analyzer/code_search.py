"""Busca por termos e conceitos relacionados à pergunta."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

# expansões semânticas leves por domínio
_EXPAND = {
    "login": ["login", "auth", "signin", "sign_in", "sign-in", "token", "session", "oauth", "google", "firebase", "user", "password", "credential"],
    "auth": ["auth", "login", "token", "jwt", "oauth", "session", "firebase", "google_sign"],
    "memoria": ["memory", "memoria", "fact", "prefs", "shared_preferences", "user_id"],
    "memory": ["memory", "fact", "prefs", "shared_preferences"],
    "chat": ["chat", "message", "stream", "conversation", "ollama"],
    "api": ["api", "http", "dio", "endpoint", "route", "fastapi", "request"],
    "erro": ["error", "exception", "fail", "bug", "crash", "stack"],
    "error": ["error", "exception", "fail", "bug", "crash"],
    "ui": ["widget", "screen", "build", "scaffold", "drawer"],
    "banco": ["database", "sqlite", "hive", "firestore", "sql"],
}


def expand_query(query: str) -> list[str]:
    q = (query or "").lower()
    terms: list[str] = []
    # tokens alfanuméricos
    for t in re.findall(r"[a-zA-ZÀ-ÿ_][\wÀ-ÿ]{2,}", q):
        tl = t.lower()
        if tl not in terms:
            terms.append(tl)
        for k, vals in _EXPAND.items():
            if k in tl or tl in k:
                for v in vals:
                    if v not in terms:
                        terms.append(v)
    # domain triggers in full query
    for k, vals in _EXPAND.items():
        if k in q:
            for v in vals:
                if v not in terms:
                    terms.append(v)
    return terms[:40] or ["main", "app", "config"]


def score_file(path: str, text: str, terms: list[str], important: bool) -> float:
    pl = path.lower()
    tl = text.lower()
    score = 0.0
    for t in terms:
        if t in pl:
            score += 4.0
        c = tl.count(t)
        if c:
            score += min(c, 12) * 1.2
    if important:
        score += 2.5
    # prefer source over generated noise
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
    max_read: int = 80,
) -> list[dict[str, Any]]:
    terms = expand_query(query)
    scored: list[dict[str, Any]] = []

    # always include important config files
    priority = [
        f
        for f in file_metas
        if f.get("important")
        or Path(f["path"]).name.lower()
        in {
            "pubspec.yaml",
            "package.json",
            "main.dart",
            "main.py",
            "app.dart",
            "auth_service.dart",
            "login_screen.dart",
        }
    ][:12]

    candidates = priority + [f for f in file_metas if f not in priority]
    candidates = candidates[: max(max_read, top_k * 3)]

    for meta in candidates:
        path = root / meta["path"]
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        if len(text) > 200_000:
            text = text[:200_000]
        sc = score_file(meta["path"], text, terms, bool(meta.get("important")))
        if sc <= 0 and not meta.get("important"):
            continue
        scored.append(
            {
                **meta,
                "score": sc,
                "preview": text[:500],
                "text": text,
            }
        )

    scored.sort(key=lambda x: -x["score"])
    return scored[:top_k]
