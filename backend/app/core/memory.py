"""
Memória de longo prazo da Gamma.
"""

from __future__ import annotations

import json
import os
import re
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import List


def _data_dir() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    if env:
        return Path(env)
    # padrão: backend/data
    return Path(__file__).resolve().parents[2] / "data"


_MEMORY_FILE = _data_dir() / "memory.json"
_lock = threading.Lock()


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class MemoryStore:
    MAX_FACTS = 40

    def __init__(self, path: Path | None = None):
        self.path = path or _MEMORY_FILE
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self._write({"facts": []})

    def _read(self) -> dict:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {"facts": []}

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def list_facts(self) -> List[dict]:
        with _lock:
            return list(self._read().get("facts", []))

    def add_fact(self, text: str, source: str = "user") -> dict:
        text = text.strip()
        if not text:
            raise ValueError("Fato vazio")

        with _lock:
            data = self._read()
            facts = data.get("facts", [])
            normalized = text.lower()
            for f in facts:
                if f.get("text", "").lower() == normalized:
                    return f

            item = {
                "id": str(int(datetime.now().timestamp() * 1000)),
                "text": text,
                "created_at": _utc_now(),
                "source": source,
            }
            facts.append(item)
            if len(facts) > self.MAX_FACTS:
                facts = facts[-self.MAX_FACTS :]
            data["facts"] = facts
            self._write(data)
            return item

    def remove_fact(self, fact_id: str) -> bool:
        with _lock:
            data = self._read()
            facts = data.get("facts", [])
            new_facts = [f for f in facts if f.get("id") != fact_id]
            if len(new_facts) == len(facts):
                return False
            data["facts"] = new_facts
            self._write(data)
            return True

    def clear(self) -> None:
        with _lock:
            self._write({"facts": []})

    def as_prompt_block(self) -> str:
        facts = self.list_facts()
        if not facts:
            return ""
        lines = [f"- {f['text']}" for f in facts]
        return (
            "MEMÓRIA DE LONGO PRAZO (fatos sobre o usuário e preferências):\n"
            + "\n".join(lines)
            + "\n\nUse esses fatos quando forem relevantes. "
            "Não invente fatos além dos listados. "
            "Se algo parecer desatualizado, peça confirmação."
        )


_REMEMBER_PATTERNS = [
    re.compile(
        r"(?:lembre(?:-se)?|lembra|grave|anote|salva(?:r)?(?:\s+na\s+mem[oó]ria)?)\s+(?:que\s+)?(.+)",
        re.IGNORECASE,
    ),
    re.compile(r"(?:remember(?:\s+that)?|note\s+that)\s+(.+)", re.IGNORECASE),
    re.compile(r"meu nome [eé]\s+(.+)", re.IGNORECASE),
    re.compile(
        r"eu (?:sou|trabalho(?:\s+como)?|prefiro|uso)\s+(.+)",
        re.IGNORECASE,
    ),
]


def try_extract_memory(user_text: str) -> str | None:
    text = user_text.strip()
    if len(text) < 8 or len(text) > 300:
        return None
    for pattern in _REMEMBER_PATTERNS:
        m = pattern.search(text)
        if m:
            fact = m.group(1).strip().rstrip(".")
            if len(fact) >= 3:
                return fact
    return None


memory_store = MemoryStore()
