"""
Conversas sincronizadas por usuário (Android / Windows / etc.).

Arquivo: data/conversations/{user_id}.json
"""

from __future__ import annotations

import json
import os
import re
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


def _data_dir() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[2] / "data"


_lock = threading.Lock()


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_user_id(user_id: Optional[str]) -> str:
    uid = (user_id or "default").strip() or "default"
    uid = re.sub(r"[^\w\-\.@]+", "_", uid)[:120]
    return uid or "default"


def _parse_ts(value: Any) -> datetime:
    if value is None:
        return datetime.min.replace(tzinfo=timezone.utc)
    if isinstance(value, (int, float)):
        # epoch ms or s
        ts = float(value)
        if ts > 1e12:
            ts = ts / 1000.0
        return datetime.fromtimestamp(ts, tz=timezone.utc)
    s = str(value).strip()
    if not s:
        return datetime.min.replace(tzinfo=timezone.utc)
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return datetime.min.replace(tzinfo=timezone.utc)


class ConversationStore:
    MAX_CONVERSATIONS = 200
    MAX_MESSAGES_PER_CONV = 500

    def __init__(self, user_id: Optional[str] = None):
        self.user_id = _safe_user_id(user_id)
        self.path = _data_dir() / "conversations" / f"{self.user_id}.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self._write({"user_id": self.user_id, "conversations": {}})

    def _read(self) -> dict:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict):
                return {"user_id": self.user_id, "conversations": {}}
            data.setdefault("conversations", {})
            if not isinstance(data["conversations"], dict):
                data["conversations"] = {}
            data["user_id"] = self.user_id
            return data
        except Exception:
            return {"user_id": self.user_id, "conversations": {}}

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data["user_id"] = self.user_id
        data["updated_at"] = _utc_now()
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def list_conversations(self, include_messages: bool = True) -> List[dict]:
        with _lock:
            convs = self._read().get("conversations", {})
            items = list(convs.values())
            items.sort(
                key=lambda c: _parse_ts(c.get("updatedAt") or c.get("updated_at")),
                reverse=True,
            )
            if not include_messages:
                out = []
                for c in items:
                    copy = dict(c)
                    msgs = copy.get("messages") or []
                    copy["messageCount"] = len(msgs)
                    copy.pop("messages", None)
                    out.append(copy)
                return out
            return items

    def get(self, conversation_id: str) -> Optional[dict]:
        with _lock:
            return self._read().get("conversations", {}).get(conversation_id)

    def upsert(self, payload: dict) -> dict:
        """
        Cria ou atualiza uma conversa com mensagens.
        payload: id, title, isPinned, createdAt, updatedAt, messages[]
        """
        cid = str(payload.get("id") or "").strip()
        if not cid:
            raise ValueError("id obrigatório")

        title = (payload.get("title") or "Nova conversa").strip() or "Nova conversa"
        is_pinned = bool(payload.get("isPinned", payload.get("is_pinned", False)))
        created_at = payload.get("createdAt") or payload.get("created_at") or _utc_now()
        updated_at = payload.get("updatedAt") or payload.get("updated_at") or _utc_now()

        raw_msgs = payload.get("messages") or []
        messages: List[dict] = []
        if isinstance(raw_msgs, list):
            for m in raw_msgs[-self.MAX_MESSAGES_PER_CONV :]:
                if not isinstance(m, dict):
                    continue
                mid = str(m.get("id") or "").strip()
                role = str(m.get("role") or "").strip()
                content = str(m.get("content") or "")
                if not mid or role not in {"user", "assistant", "system"}:
                    continue
                if not content.strip():
                    continue
                messages.append(
                    {
                        "id": mid,
                        "role": role,
                        "content": content,
                        "conversationId": cid,
                        "timestamp": m.get("timestamp")
                        or m.get("createdAt")
                        or _utc_now(),
                    }
                )

        item = {
            "id": cid,
            "title": title[:200],
            "isPinned": is_pinned,
            "createdAt": created_at
            if isinstance(created_at, str)
            else _utc_now(),
            "updatedAt": updated_at
            if isinstance(updated_at, str)
            else _utc_now(),
            "messages": messages,
        }

        with _lock:
            data = self._read()
            convs: Dict[str, Any] = data.get("conversations", {})
            existing = convs.get(cid)
            if existing:
                # Mantém o updatedAt mais recente se o cliente mandar antigo
                if _parse_ts(existing.get("updatedAt")) > _parse_ts(
                    item.get("updatedAt")
                ):
                    # Cliente desatualizado: não sobrescreve com dados mais velhos,
                    # mas ainda aceita se tiver mais mensagens (merge simples).
                    if len(messages) <= len(existing.get("messages") or []):
                        return existing

            convs[cid] = item

            # Limita quantidade de conversas (remove as mais antigas sem pin)
            if len(convs) > self.MAX_CONVERSATIONS:
                ordered = sorted(
                    convs.values(),
                    key=lambda c: (
                        1 if c.get("isPinned") else 0,
                        _parse_ts(c.get("updatedAt")),
                    ),
                )
                while len(ordered) > self.MAX_CONVERSATIONS:
                    drop = ordered.pop(0)
                    convs.pop(drop["id"], None)

            data["conversations"] = convs
            self._write(data)
            return item

    def delete(self, conversation_id: str) -> bool:
        with _lock:
            data = self._read()
            convs = data.get("conversations", {})
            if conversation_id not in convs:
                return False
            del convs[conversation_id]
            data["conversations"] = convs
            self._write(data)
            return True

    def clear(self) -> None:
        with _lock:
            self._write({"user_id": self.user_id, "conversations": {}})


_stores: Dict[str, ConversationStore] = {}
_stores_lock = threading.Lock()


def get_conversation_store(user_id: Optional[str] = None) -> ConversationStore:
    uid = _safe_user_id(user_id)
    with _stores_lock:
        if uid not in _stores:
            _stores[uid] = ConversationStore(uid)
        return _stores[uid]
