"""Sessão por conversa — o que foi enviado e o que a Gama já fez neste chat.

Não é memória global do usuário (isso continua em memory.py).
É estado da conversa atual: projeto ativo, links, arquivos, ações, artefatos.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Any, Optional

_lock = threading.Lock()
_TTL_SEC = 48 * 3600  # 48h


def _root() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    base = Path(env) if env else Path(__file__).resolve().parents[2] / "data"
    p = base / "conversation_sessions"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _safe(s: str, n: int = 64) -> str:
    return re.sub(r"[^\w\-\.]+", "_", (s or "default").strip())[:n] or "default"


def session_key(user_id: Optional[str], conversation_id: Optional[str], messages: list | None = None) -> str:
    """Chave estável da conversa.

    Prioridade: conversation_id do cliente → fingerprint do início do histórico.
    """
    uid = _safe(user_id or "default", 80)
    cid = (conversation_id or "").strip()
    if cid:
        return f"{uid}__{_safe(cid, 80)}"

    # fallback: hash das primeiras mensagens (mesmo chat sem id explícito)
    parts: list[str] = []
    for m in (messages or [])[:4]:
        role = m.get("role") or ""
        content = m.get("content") or ""
        if isinstance(content, list):
            content = " ".join(
                str(p.get("text") or "") for p in content if isinstance(p, dict)
            )
        parts.append(f"{role}:{str(content)[:200]}")
    digest = hashlib.sha1("\n".join(parts).encode("utf-8", errors="replace")).hexdigest()[:16]
    return f"{uid}__auto_{digest}"


def _path(key: str) -> Path:
    return _root() / f"{_safe(key, 120)}.json"


def load_session(key: str) -> dict[str, Any]:
    path = _path(key)
    if not path.exists():
        return _empty(key)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if time.time() - float(data.get("updated_at", 0)) > _TTL_SEC:
            return _empty(key)
        data.setdefault("key", key)
        return data
    except Exception:
        return _empty(key)


def _empty(key: str) -> dict[str, Any]:
    return {
        "key": key,
        "updated_at": time.time(),
        "active_project_id": None,
        "project_name": None,
        "project_source": None,  # zip | github | pdf | direct
        "github_url": None,
        "urls": [],
        "files_mentioned": [],
        "artifacts": [],  # {id, kind, filename}
        "actions": [],  # strings curtas do que foi feito
        "notes": [],  # fatos/decisões desta conversa
    }


def save_session(data: dict[str, Any]) -> None:
    key = data.get("key") or "default"
    data["updated_at"] = time.time()
    # limita listas
    data["urls"] = list(dict.fromkeys(data.get("urls") or []))[:30]
    data["files_mentioned"] = list(dict.fromkeys(data.get("files_mentioned") or []))[:40]
    data["artifacts"] = (data.get("artifacts") or [])[-20:]
    data["actions"] = (data.get("actions") or [])[-40:]
    data["notes"] = (data.get("notes") or [])[-40:]
    with _lock:
        _path(key).write_text(
            json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
        )


def update_from_user_message(session: dict[str, Any], text: str) -> dict[str, Any]:
    """Extrai sinais da mensagem do usuário e atualiza a sessão."""
    if not text:
        return session

    # GitHub
    m = re.search(
        r"https?://(?:www\.)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)",
        text,
        re.I,
    )
    if m:
        url = m.group(0).rstrip(".,;:!?)/")
        session["github_url"] = url
        if url not in (session.get("urls") or []):
            session.setdefault("urls", []).append(url)

    # project_id marker
    m = re.search(r"\[project_id:([a-zA-Z0-9_\-]{6,32})\]", text)
    if m:
        session["active_project_id"] = m.group(1)

    # paths de arquivo mencionados
    for path in re.findall(
        r"(?:^|[\s`\"'(])((?:lib|app|src|backend|ios|android|test|tests)/[\w./\-]+\.\w{1,10})",
        text,
        re.M,
    ):
        if path not in (session.get("files_mentioned") or []):
            session.setdefault("files_mentioned", []).append(path)

    for path in re.findall(r"\b([\w\-]+/[\w./\-]+\.(?:dart|py|ts|js|yaml|json|md))\b", text):
        if path not in (session.get("files_mentioned") or []):
            session.setdefault("files_mentioned", []).append(path)

    for path in re.findall(
        r"\b([\w\-./]+\.(?:dart|py|ts|tsx|js|jsx|java|kt|go|rs|swift|cs|yaml|yml|json|md))\b",
        text,
        re.I,
    ):
        if path not in (session.get("files_mentioned") or []):
            session.setdefault("files_mentioned", []).append(path)

    # urls genéricas
    for u in re.findall(r"https?://[^\s\)\]\>\"']+", text):
        u = u.rstrip(".,;:!?")
        if u not in (session.get("urls") or []):
            session.setdefault("urls", []).append(u)

    return session


def set_active_project(
    session: dict[str, Any],
    *,
    project_id: str,
    name: Optional[str] = None,
    source: Optional[str] = None,
) -> dict[str, Any]:
    session["active_project_id"] = project_id
    if name:
        session["project_name"] = name
    if source:
        session["project_source"] = source
    session.setdefault("actions", []).append(
        f"Projeto ativo: {name or project_id} ({source or 'unknown'})"
    )
    return session


def add_action(session: dict[str, Any], action: str) -> dict[str, Any]:
    if action and action not in (session.get("actions") or [])[-5:]:
        session.setdefault("actions", []).append(action[:240])
    return session


def add_artifact(
    session: dict[str, Any],
    *,
    artifact_id: str,
    kind: str,
    filename: str,
) -> dict[str, Any]:
    session.setdefault("artifacts", []).append(
        {"id": artifact_id, "kind": kind, "filename": filename}
    )
    session.setdefault("actions", []).append(f"Artefato gerado: {filename} ({kind})")
    return session


def as_prompt_block(session: dict[str, Any]) -> str:
    """Bloco injetado no system prompt — estado desta conversa."""
    if not session:
        return ""

    lines = [
        "[ESTADO DESTA CONVERSA — use sempre; não peça de novo o que já está aqui]",
    ]

    pid = session.get("active_project_id")
    if pid:
        lines.append(
            f"Projeto ativo: project_id={pid}"
            + (f" nome={session.get('project_name')}" if session.get("project_name") else "")
            + (f" origem={session.get('project_source')}" if session.get("project_source") else "")
        )
        lines.append(
            "Se o usuário falar em 'esse repo', 'o projeto', 'main.dart', etc., "
            "use este project_id / Code Analyzer. "
            "NUNCA diga que não tem o arquivo se o Code Analyzer injetou o conteúdo "
            "ou se o project_id está ativo — leia o bloco de contexto e responda com base nele. "
            "Se um arquivo for pedido pelo nome (ex.: main.dart), o analyzer carrega o texto; "
            "reproduza ou explique com base nesse texto."
        )

    if session.get("github_url"):
        lines.append(f"GitHub desta conversa: {session['github_url']}")

    files = session.get("files_mentioned") or []
    if files:
        lines.append("Arquivos já mencionados: " + ", ".join(files[:20]))

    urls = [u for u in (session.get("urls") or []) if u != session.get("github_url")]
    if urls:
        lines.append("Links já enviados: " + ", ".join(urls[:10]))

    arts = session.get("artifacts") or []
    if arts:
        lines.append(
            "Artefatos já gerados nesta conversa: "
            + ", ".join(f"{a.get('filename')}({a.get('id')})" for a in arts[-8:])
        )

    actions = session.get("actions") or []
    if actions:
        lines.append("O que já foi feito neste chat:")
        for a in actions[-12:]:
            lines.append(f"- {a}")

    notes = session.get("notes") or []
    if notes:
        lines.append("Notas desta conversa:")
        for n in notes[-8:]:
            lines.append(f"- {n}")

    if len(lines) <= 1:
        return ""
    return "\n".join(lines)
