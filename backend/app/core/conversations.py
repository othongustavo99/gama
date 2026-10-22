"""
Conversas sincronizadas por usuário (Android / Windows / etc.).

Arquivos: data/conversations/{user_id}/{conversation_id}.json
O arquivo único legado é migrado sem ser descartado até a cópia atômica concluir.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
import threading
import uuid
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
        try:
            return datetime.fromtimestamp(ts, tz=timezone.utc)
        except (OverflowError, OSError, ValueError):
            return datetime.min.replace(tzinfo=timezone.utc)
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
    # Nenhuma conversa é descartada automaticamente durante um upsert.
    # Não corte mensagens antigas: o cliente pode sincronizar conversas extensas.
    # O controle de tráfego/paginação deve acontecer na API, não apagando dados.

    def __init__(self, user_id: Optional[str] = None):
        self.user_id = _safe_user_id(user_id)
        self.path = _data_dir() / "conversations" / f"{self.user_id}.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.conversations_dir = self.path.with_suffix("")
        self.conversations_dir.mkdir(parents=True, exist_ok=True)
        with _lock:
            self._migrate_legacy_file()

    def _conversation_path(self, conversation_id: str) -> Path:
        safe_id = re.sub(r"[^\w.-]+", "_", str(conversation_id))[:180]
        if not safe_id or safe_id in {".", ".."}:
            raise ValueError("id de conversa inválido")
        return self.conversations_dir / f"{safe_id}.json"

    @staticmethod
    def _atomic_json_write(path: Path, data: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent)
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.flush()
                try:
                    os.fsync(f.fileno())
                except OSError:
                    pass
            os.replace(tmp_name, path)
        finally:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass

    def _migrate_legacy_file(self) -> None:
        """Migra o arquivo antigo sem removê-lo até gravar cada conversa."""
        if not self.path.exists():
            return
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            conversations = data.get("conversations", {}) if isinstance(data, dict) else {}
            if not isinstance(conversations, dict):
                return
            for item in conversations.values():
                if isinstance(item, dict) and item.get("id"):
                    target = self._conversation_path(str(item["id"]))
                    if not target.exists():
                        self._atomic_json_write(target, item)
            # Todas as conversas já estão gravadas atomicamente em seus arquivos.
            self.path.unlink(missing_ok=True)
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            # Mantém o original intacto se a migração estiver incompleta.
            return

    def _read(self) -> dict:
        data = {"user_id": self.user_id, "conversations": {}}
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                legacy = json.load(f)
            if isinstance(legacy, dict) and isinstance(legacy.get("conversations"), dict):
                data["conversations"].update(legacy["conversations"])
        except (OSError, ValueError, TypeError):
            pass
        try:
            for path in self.conversations_dir.glob("*.json"):
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        item = json.load(f)
                    if isinstance(item, dict) and item.get("id"):
                        data["conversations"][str(item["id"])] = item
                except (OSError, ValueError, TypeError):
                    # Uma conversa danificada não apaga as outras.
                    continue
        except OSError:
            pass
        return data

    def _read_conversation(self, conversation_id: str) -> Optional[dict]:
        try:
            with open(self._conversation_path(conversation_id), "r", encoding="utf-8") as f:
                item = json.load(f)
            return item if isinstance(item, dict) else None
        except FileNotFoundError:
            pass
        except (OSError, ValueError, TypeError):
            return None
        # Fallback during a partial legacy migration; never rewrites the source.
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                legacy = json.load(f)
            item = (legacy.get("conversations") or {}).get(conversation_id)
            return item if isinstance(item, dict) else None
        except (OSError, ValueError, TypeError):
            return None

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data["user_id"] = self.user_id
        data["updated_at"] = _utc_now()
        self._atomic_json_write(self.path, data)

    def _write_conversation(self, item: dict) -> None:
        # Versão opaca que muda a cada gravação confirmada. Diferente de
        # updatedAt, não depende do relógio do telefone e inclui tombstones,
        # edições de mensagem e alterações de metadados.
        item["user_id"] = self.user_id
        item["syncRevision"] = uuid.uuid4().hex
        self._atomic_json_write(self._conversation_path(item["id"]), item)

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
            return self._read_conversation(conversation_id)

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
            for m in raw_msgs:
                if not isinstance(m, dict):
                    continue
                mid = str(m.get("id") or "").strip()
                role = str(m.get("role") or "").strip()
                content = str(m.get("content") or "")
                if not mid or role not in {"user", "assistant", "system"}:
                    continue
                if not content.strip():
                    continue
                normalized_message = {
                    "id": mid,
                    "role": role,
                    "content": content,
                    "conversationId": cid,
                    "timestamp": m.get("timestamp")
                    or m.get("createdAt")
                    or _utc_now(),
                }
                metadata = m.get("attachmentMetadataJson")
                if isinstance(metadata, str) and len(metadata) <= 100_000:
                    normalized_message["attachmentMetadataJson"] = metadata
                raw_variants = m.get("variants")
                if isinstance(raw_variants, list):
                    # Um teto reduz crescimento ilimitado do histórico sincronizado.
                    normalized_variants = [str(v)[:250_000] for v in raw_variants[-12:]]
                    normalized_message["variants"] = normalized_variants
                    try:
                        selected = int(m.get("selectedVariantIndex", 0))
                    except (TypeError, ValueError):
                        selected = 0
                    normalized_message["selectedVariantIndex"] = max(
                        0, min(selected, max(0, len(normalized_variants) - 1))
                    )
                normalized_message["isTruncated"] = bool(m.get("isTruncated", False))
                sources_json = m.get("sourcesJson")
                if isinstance(sources_json, str) and len(sources_json) <= 100_000:
                    normalized_message["sourcesJson"] = sources_json
                messages.append(normalized_message)

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
            "mode": payload.get("mode"),
        }

        with _lock:
            data = self._read()
            convs: Dict[str, Any] = data.get("conversations", {})
            existing = convs.get(cid)
            if existing:
                deleted = set(existing.get("deletedMessageIds") or [])
                deleted.update(item.get("deletedMessageIds") or [])
                merged = {
                    str(message.get("id")): message
                    for message in existing.get("messages", [])
                    if str(message.get("id")) not in deleted
                }
                for message in messages:
                    mid = str(message.get("id"))
                    if mid in deleted:
                        continue
                    previous = merged.get(mid)
                    if previous is None or _parse_ts(previous.get("timestamp")) <= _parse_ts(message.get("timestamp")):
                        merged[mid] = message
                item["messages"] = sorted(
                    merged.values(), key=lambda message: (_parse_ts(message.get("timestamp")), str(message.get("id")))
                )
                # Tombstones não devem expirar: um aparelho offline pode voltar
                # após meses e não pode ressuscitar mensagens excluídas.
                item["deletedMessageIds"] = sorted(deleted)
                incoming_is_current = (
                    _parse_ts(item.get("updatedAt")) >= _parse_ts(existing.get("updatedAt"))
                )
                if not incoming_is_current:
                    for key in ("title", "isPinned", "createdAt", "updatedAt"):
                        item[key] = existing.get(key, item[key])
                    item["mode"] = existing.get("mode")
                elif item["mode"] is None:
                    # Clientes antigos não conhecem 'mode'; não apague Oficina.
                    item["mode"] = existing.get("mode")

            convs[cid] = item

            # Não elimine conversas antigas ao chegar a um limite arbitrário.
            # Apenas DELETE explícito pode remover uma conversa do servidor.

            data["conversations"] = convs
            self._write_conversation(item)
            return item

    def update_metadata(self, conversation_id: str, updates: dict) -> bool:
        """Altera apenas os metadados, sem reserializar/truncar as mensagens."""
        with _lock:
            item = self._read_conversation(conversation_id)
            if item is None:
                return False
            incoming_updated_at = updates.get("updatedAt")
            if incoming_updated_at is not None and (
                _parse_ts(incoming_updated_at) < _parse_ts(item.get("updatedAt"))
            ):
                # Protege título/pin/modo alterados em outro dispositivo.
                return True
            for key in ("title", "isPinned", "mode"):
                if key in updates:
                    value = updates[key]
                    if key == "title":
                        value = str(value or "Nova conversa").strip()[:200] or "Nova conversa"
                    elif key == "isPinned":
                        value = bool(value)
                    item[key] = value
            item["updatedAt"] = incoming_updated_at or _utc_now()
            self._write_conversation(item)
            return True

    def upsert_message(self, conversation_id: str, payload: dict, message: dict) -> dict:
        """Mescla uma mensagem por ID e grava só o arquivo desta conversa."""
        with _lock:
            existing = self._read_conversation(conversation_id) or {
                "id": conversation_id,
                "title": payload.get("title") or "Nova conversa",
                "isPinned": bool(payload.get("isPinned", False)),
                "createdAt": payload.get("createdAt") or _utc_now(),
                "updatedAt": payload.get("updatedAt") or _utc_now(),
                "messages": [],
                "deletedMessageIds": [],
            }
            normalized = self._normalize_message(conversation_id, message)
            deleted = set(existing.get("deletedMessageIds") or [])
            if normalized["id"] not in deleted:
                messages = list(existing.get("messages") or [])
                by_id = {str(m.get("id")): i for i, m in enumerate(messages)}
                old_index = by_id.get(normalized["id"])
                if old_index is None:
                    messages.append(normalized)
                elif _parse_ts(messages[old_index].get("timestamp")) <= _parse_ts(normalized.get("timestamp")):
                    messages[old_index] = normalized
                existing["messages"] = messages
            for key in ("title", "isPinned", "createdAt", "updatedAt"):
                if key in payload and payload[key] is not None:
                    existing[key] = payload[key]
            existing["updatedAt"] = max(
                str(existing.get("updatedAt") or ""),
                str(payload.get("updatedAt") or _utc_now()),
            )
            self._write_conversation(existing)
            return existing

    def delete_messages(self, conversation_id: str, message_ids: List[str]) -> Optional[dict]:
        with _lock:
            item = self._read_conversation(conversation_id)
            if item is None:
                return None
            deleted = set(item.get("deletedMessageIds") or [])
            deleted.update(str(message_id) for message_id in message_ids if message_id)
            item["deletedMessageIds"] = sorted(deleted)
            item["messages"] = [
                m for m in item.get("messages", []) if str(m.get("id")) not in deleted
            ]
            item["updatedAt"] = _utc_now()
            self._write_conversation(item)
            return item

    def _normalize_message(self, cid: str, m: dict) -> dict:
        mid = str(m.get("id") or "").strip()
        role = str(m.get("role") or "").strip()
        content = str(m.get("content") or "")
        if not mid or role not in {"user", "assistant", "system"}:
            raise ValueError("mensagem inválida")
        normalized = {
            "id": mid,
            "role": role,
            "content": content,
            "conversationId": cid,
            "timestamp": m.get("timestamp") or m.get("createdAt") or _utc_now(),
        }
        metadata = m.get("attachmentMetadataJson")
        if isinstance(metadata, str) and len(metadata) <= 100_000:
            normalized["attachmentMetadataJson"] = metadata
        raw_variants = m.get("variants")
        if isinstance(raw_variants, list):
            variants = [str(v)[:250_000] for v in raw_variants[-12:]]
            normalized["variants"] = variants
            try:
                selected = int(m.get("selectedVariantIndex", 0))
            except (TypeError, ValueError):
                selected = 0
            normalized["selectedVariantIndex"] = max(0, min(selected, max(0, len(variants) - 1)))
        normalized["isTruncated"] = bool(m.get("isTruncated", False))
        sources_json = m.get("sourcesJson")
        if isinstance(sources_json, str) and len(sources_json) <= 100_000:
            normalized["sourcesJson"] = sources_json
        return normalized

    def delete(self, conversation_id: str) -> bool:
        with _lock:
            data = self._read()
            convs = data.get("conversations", {})
            if conversation_id not in convs:
                return False
            del convs[conversation_id]
            try:
                self._conversation_path(conversation_id).unlink(missing_ok=True)
            except OSError:
                return False
            data["conversations"] = convs
            return True

    def clear(self) -> None:
        with _lock:
            for path in self.conversations_dir.glob("*.json"):
                path.unlink(missing_ok=True)
            self.path.unlink(missing_ok=True)
            self.path.with_suffix(".json.migrated").unlink(missing_ok=True)


_stores: Dict[str, ConversationStore] = {}
_stores_lock = threading.Lock()


def get_conversation_store(user_id: Optional[str] = None) -> ConversationStore:
    uid = _safe_user_id(user_id)
    with _stores_lock:
        if uid not in _stores:
            _stores[uid] = ConversationStore(uid)
        return _stores[uid]
