"""
Memória de longo prazo da Gamma — por usuário.

- Arquivo: data/memory/{user_id}.json
- Extração: padrões explícitos + preferências + (opcional) LLM no turno
"""

from __future__ import annotations

import json
import os
import re
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional


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
    # evita path traversal
    uid = re.sub(r"[^\w\-\.@]+", "_", uid)[:120]
    return uid or "default"


class MemoryStore:
    MAX_FACTS = 60

    def __init__(self, user_id: Optional[str] = None):
        self.user_id = _safe_user_id(user_id)
        self.path = _data_dir() / "memory" / f"{self.user_id}.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            # migra memory.json legado para default uma vez
            legacy = _data_dir() / "memory.json"
            if self.user_id == "default" and legacy.exists():
                try:
                    with open(legacy, "r", encoding="utf-8") as f:
                        data = json.load(f)
                    self._write(data if isinstance(data, dict) else {"facts": []})
                    return
                except Exception:
                    pass
            self._write({"facts": [], "user_id": self.user_id})

    def _read(self) -> dict:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict):
                return {"facts": [], "user_id": self.user_id}
            data.setdefault("facts", [])
            data["user_id"] = self.user_id
            return data
        except Exception:
            return {"facts": [], "user_id": self.user_id}

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data["user_id"] = self.user_id
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def list_facts(self) -> List[dict]:
        with _lock:
            return list(self._read().get("facts", []))

    def add_fact(self, text: str, source: str = "user") -> dict:
        text = re.sub(r"\s+", " ", (text or "").strip())
        if len(text) < 3:
            raise ValueError("Fato vazio")
        if len(text) > 400:
            text = text[:400].rstrip() + "…"

        with _lock:
            data = self._read()
            facts = data.get("facts", [])
            normalized = text.lower()
            for f in facts:
                if f.get("text", "").lower() == normalized:
                    return f
                # quase duplicata
                if normalized in f.get("text", "").lower() or f.get("text", "").lower() in normalized:
                    if len(text) > len(f.get("text", "")):
                        f["text"] = text
                        f["source"] = source
                        f["updated_at"] = _utc_now()
                        data["facts"] = facts
                        self._write(data)
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

    def add_facts(self, texts: List[str], source: str = "auto") -> List[dict]:
        out = []
        for t in texts:
            try:
                out.append(self.add_fact(t, source=source))
            except Exception:
                continue
        return out

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
            self._write({"facts": [], "user_id": self.user_id})

    def as_prompt_block(self) -> str:
        facts = self.list_facts()
        if not facts:
            return ""
        lines = [
            "MEMÓRIA DE LONGO PRAZO DESTE USUÁRIO",
            f"(user_id={self.user_id}) — use estes fatos quando forem relevantes.",
            "Não invente memória. Se algo parecer desatualizado, peça confirmação.",
            "",
        ]
        for i, f in enumerate(facts, 1):
            src = f.get("source") or "user"
            lines.append(f"{i}. [{src}] {f.get('text', '')}")
        return "\n".join(lines)


# --------------------------------------------------------------------------- extract

_REMEMBER_PATTERNS = [
    re.compile(
        r"(?:lembre(?:-se)?|lembra|grave|anote|salva(?:r)?(?:\s+na\s+mem[oó]ria)?)\s+(?:que\s+)?(.+)",
        re.IGNORECASE,
    ),
    re.compile(r"(?:remember(?:\s+that)?|note\s+that)\s+(.+)", re.IGNORECASE),
    re.compile(r"meu nome [eé]\s+(.+)", re.IGNORECASE),
    re.compile(r"me chamo\s+(.+)", re.IGNORECASE),
    re.compile(
        r"eu (?:sou|trabalho(?:\s+como)?|prefiro|uso|moro(?:\s+em)?|estudo)\s+(.+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:minha|meu)\s+(?:empresa|projeto|app|linguagem|stack|framework)\s+[eé]?\s*(.+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:n[aã]o\s+)?(?:gost[oa]|prefiro|odeio|evito)\s+(.+)",
        re.IGNORECASE,
    ),
]


def try_extract_memory(user_text: str) -> Optional[str]:
    """Extração rápida por regex (sincrono, no início do turno)."""
    text = (user_text or "").strip()
    # ignora blocos enormes de código/anexo
    if len(text) < 8 or len(text) > 500:
        return None
    if text.count("```") >= 2:
        return None
    if text.startswith("Anexos para análise"):
        return None

    for pattern in _REMEMBER_PATTERNS:
        m = pattern.search(text)
        if m:
            fact = m.group(1).strip().rstrip(".!")
            fact = re.sub(r"\s+", " ", fact)
            if 3 <= len(fact) <= 300:
                return fact
    return None


async def extract_facts_with_llm(
    *,
    user_text: str,
    assistant_text: str,
    model: str,
    llm_client,
    existing_facts: List[str],
) -> List[str]:
    """
    Após o turno: pede ao modelo 0–3 fatos estáveis sobre o usuário.
    Só grava preferências/identidade/projeto — não resumo da conversa.
    """
    user_text = (user_text or "").strip()
    assistant_text = (assistant_text or "").strip()
    if len(user_text) < 12:
        return []
    # evita gastar LLM em mensagens puramente técnicas curtas sem sinal pessoal
    if not re.search(
        r"\b(eu|meu|minha|prefiro|trabalho|projeto|app|chamo|nome|moro|empresa)\b",
        user_text,
        re.I,
    ) and not re.search(
        r"(lembre|grave|anote|mem[oó]ria)",
        user_text,
        re.I,
    ):
        return []

    existing = "\n".join(f"- {x}" for x in existing_facts[-20:]) or "(vazia)"
    prompt = f"""Você extrai memória de longo prazo de um assistente pessoal.

Regras:
- Retorne APENAS um JSON array de strings (0 a 3 itens).
- Cada item é um fato ESTÁVEL sobre o USUÁRIO (nome, preferências, stack, projeto, restrições).
- NÃO grave: resumo da conversa, código pontual, perguntas, opiniões da IA.
- NÃO repita fatos já existentes.
- Se não houver nada estável, retorne [].

Fatos já gravados:
{existing}

Mensagem do usuário:
\"\"\"{user_text[:1200]}\"\"\"

Trecho da resposta da assistente (contexto):
\"\"\"{assistant_text[:800]}\"\"\"

JSON array:"""

    try:
        raw = await llm_client.chat_once(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            timeout=45.0,
        )
        raw = (raw or "").strip()
        # extrai array
        m = re.search(r"\[[\s\S]*\]", raw)
        if not m:
            return []
        data = json.loads(m.group(0))
        if not isinstance(data, list):
            return []
        out = []
        for item in data[:3]:
            if isinstance(item, str) and 3 <= len(item.strip()) <= 300:
                out.append(item.strip())
        return out
    except Exception:
        return []


def get_store(user_id: Optional[str] = None) -> MemoryStore:
    return MemoryStore(user_id=user_id)


# compat: store default (rotas antigas)
memory_store = MemoryStore(user_id="default")
