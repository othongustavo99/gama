"""Contexto da conversa enviado ao modelo (v2: resumo rolante persistente).

- Cabe no limite -> envia tudo.
- Passa do limite -> mantém as mensagens recentes e troca o início por um RESUMO
  que é guardado em disco por (usuário, conversa) e atualizado em segundo plano
  depois da resposta (não bloqueia o turno). Na v1 o "resumo" era só cada
  mensagem cortada em 120 caracteres.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

_IMG_RE = re.compile(r"\[gama_image\][\s\S]*?\[/gama_image\]")
MAX_MSG_CHARS = 12_000
REFRESH_GAP = 8  # mensagens novas fora da janela antes de re-resumir


def _text_of(content: Any) -> str:
    """Texto de uma mensagem (aceita str ou lista multimodal OpenAI)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            str(p.get("text") or "") for p in content if isinstance(p, dict) and p.get("type", "text") == "text"
        )
    return str(content or "")


def normalize_messages(messages: List[Dict[str, Any]]) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    for m in messages or []:
        content = _text_of(m.get("content")).strip()
        if not content:
            continue
        if "[gama_image]" in content:
            content = _IMG_RE.sub("[imagem gerada anteriormente]", content)
        if len(content) > MAX_MSG_CHARS:
            content = content[:MAX_MSG_CHARS] + "\n…[cortado]"
        out.append({"role": m.get("role", "user"), "content": content})
    return out


def _hash(msg: Dict[str, str]) -> str:
    return hashlib.sha1(f"{msg['role']}\n{msg['content']}".encode("utf-8")).hexdigest()[:12]


# --------------------------------------------------------------------------- persistência

def _data_dir() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    return Path(env) if env else Path(__file__).resolve().parents[2] / "data"


def _safe(uid: Optional[str]) -> str:
    uid = re.sub(r"[^\w\-\.@]+", "_", (uid or "default").strip() or "default")[:120]
    return uid.strip(".") or "default"


class SummaryStore:
    MAX_CONVERSATIONS = 100
    _lock = threading.Lock()

    def __init__(self, user_id: Optional[str]):
        self.path = _data_dir() / "summaries" / f"{_safe(user_id)}.json"

    def _read(self) -> dict:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError):
            return {}

    def get(self, conversation_id: Optional[str]) -> Optional[dict]:
        if not conversation_id:
            return None
        with self._lock:
            return self._read().get(conversation_id)

    def put(self, conversation_id: str, state: dict) -> None:
        with self._lock:
            data = self._read()
            state = dict(state)
            state["updated_at"] = datetime.now(timezone.utc).isoformat()
            data[conversation_id] = state
            if len(data) > self.MAX_CONVERSATIONS:
                for key in sorted(data, key=lambda k: data[k].get("updated_at", ""))[: len(data) - self.MAX_CONVERSATIONS]:
                    data.pop(key, None)
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".json.tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, self.path)


# --------------------------------------------------------------------------- manager

class ContextManager:
    def __init__(self, max_messages: int = 48, summary_max_chars: int = 2500, keep_recent: int = 24):
        self.max_messages = max_messages
        self.summary_max_chars = summary_max_chars
        self.keep_recent = keep_recent

    async def prepare(self, messages: List[Dict[str, Any]], **_ignored) -> List[Dict[str, str]]:
        """Compat com a v1: devolve só a lista de mensagens."""
        ctx, _info = self.prepare_with_summary(messages, None)
        return ctx

    def prepare_with_summary(
        self, messages: List[Dict[str, Any]], state: Optional[dict]
    ) -> Tuple[List[Dict[str, str]], dict]:
        normalized = normalize_messages(messages)
        info: dict = {"needs_refresh": False}
        if len(normalized) <= self.max_messages:
            return normalized, info

        older = normalized[: -self.keep_recent]
        recent = normalized[-self.keep_recent :]
        first_hash = _hash(older[0])

        covered = 0
        summary = ""
        if state and state.get("first_hash") == first_hash and 0 < int(state.get("covered", 0)) <= len(older):
            covered = int(state["covered"])
            summary = str(state.get("summary") or "")
        gap = older[covered:]

        if summary:
            text = summary
            if gap:
                text += "\n\n[Trocas mais recentes ainda não resumidas]\n" + self._local_summary(gap, 1200)
        else:
            text = self._local_summary(older, self.summary_max_chars)

        info.update(
            needs_refresh=len(gap) >= REFRESH_GAP,
            first_hash=first_hash,
            covered=covered,
            older_count=len(older),
        )
        if len(text) > self.summary_max_chars + 1300:
            text = text[: self.summary_max_chars + 1300] + "…"
        summary_msg = {
            "role": "system",
            "content": (
                "RESUMO DO INÍCIO DESTA CONVERSA (contexto; não é uma mensagem nova do usuário):\n" + text
            ),
        }
        return [summary_msg, *recent], info

    @staticmethod
    def _local_summary(messages: List[Dict[str, str]], limit: int) -> str:
        parts: List[str] = []
        total = 0
        for m in messages:
            snippet = m["content"].replace("\n", " ").strip()
            snippet = snippet[:160] + ("…" if len(snippet) > 160 else "")
            line = f"{'Usuário' if m['role'] == 'user' else 'Gamma'}: {snippet}"
            if total + len(line) > limit:
                break
            parts.append(line)
            total += len(line) + 1
        return "\n".join(parts)


# --------------------------------------------------------------------------- resumo em background

_in_flight: set = set()


async def refresh_summary(
    llm_client,
    model: str,
    messages: List[Dict[str, Any]],
    *,
    user_id: Optional[str],
    conversation_id: Optional[str],
    manager: Optional[ContextManager] = None,
) -> bool:
    """Atualiza o resumo persistente. Chamar com asyncio.create_task depois da resposta."""
    if not conversation_id:
        return False
    manager = manager or ContextManager()
    key = (_safe(user_id), conversation_id)
    if key in _in_flight:
        return False
    store = SummaryStore(user_id)
    normalized = normalize_messages(messages)
    if len(normalized) <= manager.max_messages:
        return False
    older = normalized[: -manager.keep_recent]
    state = store.get(conversation_id)
    _ctx, info = manager.prepare_with_summary(messages, state)
    if not info.get("needs_refresh") and state:
        return False

    covered = info.get("covered", 0)
    previous = (state or {}).get("summary", "") if covered else ""
    new_part = older[covered:]
    transcript = "\n".join(
        f"{'Usuário' if m['role'] == 'user' else 'Gamma'}: {m['content'][:600]}" for m in new_part
    )[:14_000]
    prompt = (
        "Você mantém o resumo corrido de uma conversa longa entre um usuário e a assistente Gamma.\n\n"
        f"RESUMO ATUAL:\n{previous or '(vazio)'}\n\nNOVAS MENSAGENS:\n{transcript}\n\n"
        "Escreva o resumo ATUALIZADO em português, em tópicos curtos (até ~1800 caracteres): "
        "decisões tomadas, fatos relevantes do usuário, tarefas em andamento, arquivos/caminhos e nomes "
        "citados, preferências. Preserve o que ainda importa do resumo atual. Não invente nada. "
        "Responda só com o resumo."
    )
    _in_flight.add(key)
    try:
        text = await llm_client.chat_once(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            timeout=60.0,
            max_tokens=700,
        )
        text = (text or "").strip()
        if len(text) < 40:
            return False
        store.put(
            conversation_id,
            {"summary": text[:3500], "covered": len(older), "first_hash": info["first_hash"]},
        )
        return True
    except Exception as exc:  # noqa: BLE001
        logger.warning("refresh_summary falhou: %s", exc)
        return False
    finally:
        _in_flight.discard(key)


def schedule_summary_refresh(*args, **kwargs) -> None:
    """Agenda refresh_summary sem bloquear (mantém referência para não ser coletada)."""
    task = asyncio.create_task(refresh_summary(*args, **kwargs))
    _background.add(task)
    task.add_done_callback(_background.discard)


_background: set = set()
