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
    MAX_FACTS = 100

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
        r"(?:lembre(?:-se)?|lembra|grave|anote|salva(?:r)?)\s+(?:(?:isso|isto)\s+)?(?:na\s+mem[oó]ria\s+)?(?:que\s+)?(.+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:coloca|ponha|guarda)\s+na\s+mem[oó]ria\s+(?:que\s+)?(.+)",
        re.IGNORECASE,
    ),
    re.compile(r"(?:remember(?:\s+that)?|note\s+that)\s+(.+)", re.IGNORECASE),
    # Identidade básica
    re.compile(r"meu nome [eé]\s+(.+)", re.IGNORECASE),
    re.compile(r"me chamo\s+(.+)", re.IGNORECASE),
    re.compile(r"(?:eu\s+)?tenho\s+(\d{1,3})\s*anos", re.IGNORECASE),
    re.compile(r"minha idade [eé]\s+(\d{1,3})", re.IGNORECASE),
    re.compile(r"(?:nasci|nascido|nascida)\s+(?:em|no dia|no ano)?\s*(.+)", re.IGNORECASE),
    re.compile(r"(?:sou\s+de|natural\s+de|nasci\s+em)\s+(.+)", re.IGNORECASE),
    re.compile(r"(?:moro|vivo|resido)(?:\s+em|\s+no|\s+na)?\s+(.+)", re.IGNORECASE),
    re.compile(r"(?:sou\s+)?(?:casado|casada|solteiro|solteira|divorciado|divorciada|viúvo|viúva|namorando)", re.IGNORECASE),
    re.compile(r"(?:trabalho\s+como|sou\s+|minha\s+profiss[aã]o\s+[eé])\s*(.+)", re.IGNORECASE),
    re.compile(
        r"(?:minha|meu)\s+cor\s+favorita\s+[eé]\s+(.+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"eu (?:sou|trabalho(?:\s+como)?|prefiro|uso|moro(?:\s+em)?|estudo|gosto\s+de)\s+(.+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:minha|meu)\s+(?:empresa|projeto|app|linguagem|stack|framework|time|esposa|esposo|filho|filha|família)\s+[eé]?\s*(.+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:n[aã]o\s+)?(?:gost[oa]|prefiro|odeio|evito)\s+(.+)",
        re.IGNORECASE,
    ),
]


def try_extract_memory(user_text: str) -> Optional[str]:
    """Extração rápida por regex (sincrono, no início do turno)."""
    if not isinstance(user_text, str):
        return None
    text = user_text.strip()
    if len(text) < 6 or len(text) > 800:
        return None
    if text.count("```") >= 2:
        return None
    if text.startswith("Anexos para análise"):
        return None

    for pattern in _REMEMBER_PATTERNS:
        m = pattern.search(text)
        if m:
            if m.lastindex and m.group(1):
                fact = m.group(1).strip().rstrip(".!")
            else:
                fact = m.group(0).strip().rstrip(".!")
            fact = re.sub(r"^(?:na\s+mem[oó]ria\s+)", "", fact, flags=re.I)
            fact = re.sub(r"\s+", " ", fact).strip()
            if 3 <= len(fact) <= 300:
                lower = text.lower()
                if re.search(r"cor\s+favorita", lower) and "cor favorita" not in fact.lower():
                    fact = f"Cor favorita: {fact}"
                elif re.search(r"\b(anos|idade)\b", lower) and "idade" not in fact.lower():
                    fact = f"Idade: {fact}"
                elif re.search(r"\b(moro|vivo|resido)\b", lower) and "moro" not in fact.lower() and "vivo" not in fact.lower():
                    fact = f"Mora em: {fact}"
                elif re.search(r"\b(nasci|natural\s+de)\b", lower) and "natural" not in fact.lower() and "nasci" not in fact.lower():
                    fact = f"Natural de: {fact}"
                return fact

    m = re.search(
        r"(?:minha|meu)\s+cor\s+favorita\s+[eé]\s+([^\n\.!?]+)",
        text,
        re.I,
    )
    if m:
        return f"Cor favorita: {m.group(1).strip()}"

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
    Após o turno: extrai automaticamente fatos estáveis sobre a pessoa.
    Foca em identidade, biografia e personalidade — sem precisar o usuário pedir.
    """
    user_text = (user_text or "").strip()
    assistant_text = (assistant_text or "").strip()
    if len(user_text) < 10:
        return []

    personal_signal = re.search(
        r"\b("
        r"eu|meu|minha|meus|minhas|sou|tenho|chamo|nome|"
        r"idade|anos|nasci|nascimento|anivers[aá]rio|natural|naturalidade|"
        r"moro|vivo|resido|cidade|estado|país|localidade|"
        r"casado|casada|solteiro|solteira|divorciado|divorciada|viúvo|viúva|namoro|namorando|esposa|esposo|marido|filho|filha|família|"
        r"trabalho|trabalha|profiss[aã]o|cargo|empresa|estudo|faculdade|curso|"
        r"prefiro|gosto|odeio|favorita|favorito|hobby|hobbies|"
        r"projeto|app|stack|linguagem|framework"
        r")\b",
        user_text,
        re.I,
    )
    explicit_memory = re.search(
        r"(lembre|grave|anote|mem[oó]ria|remember|note\s+that)",
        user_text,
        re.I,
    )
    if not personal_signal and not explicit_memory:
        # modo amplo: ainda tenta se a mensagem for conversacional
        if len(user_text) < 20 or user_text.count("```") >= 2:
            return []

    existing = "\n".join(f"- {x}" for x in existing_facts[-25:]) or "(vazia)"
    prompt = f"""Você é um extrator de memória de longo prazo de um assistente pessoal.

Sua única tarefa: identificar fatos ESTÁVEIS e RELEVANTES sobre a PESSOA (o usuário) que moldam quem ela é.

PRIORIDADE MÁXIMA (grave sempre que aparecer):
- Nome completo ou como prefere ser chamado
- Idade / data de nascimento / aniversário
- Naturalidade (onde nasceu) e localidade atual (cidade/estado/país onde mora)
- Estado civil (solteiro, casado, namorando, etc.) e família próxima
- Profissão, cargo, empresa, área de atuação, estudos
- Preferências fortes e estáveis (comida, cor, hobbies, valores, aversões)
- Projetos pessoais/profissionais de longo prazo, stack/tecnologias que usa
- Qualquer traço de personalidade ou restrição importante (ex: vegetariano, tem filhos, mora sozinho)

REGRAS RÍGIDAS:
1. Retorne APENAS um JSON array de strings (0 a 5 itens). Nada mais.
2. Cada string deve ser um fato claro e autocontido (ex: "Nome: Othon", "Mora em São Paulo", "Tem 34 anos", "É casado", "Trabalha como desenvolvedor Flutter").
3. NÃO grave: resumo da conversa, código pontual, perguntas, opiniões temporárias da IA, tarefas do dia.
4. NÃO repita nem parafraseie fatos já existentes abaixo.
5. Se não houver nenhum fato novo e estável, retorne exatamente [].

Fatos já gravados:
{existing}

Mensagem do usuário:
\"\"\"{user_text[:1400]}\"\"\"

Trecho da resposta da assistente (só contexto):
\"\"\"{assistant_text[:600]}\"\"\"

JSON array:"""

    try:
        raw = await llm_client.chat_once(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            timeout=45.0,
        )
        raw = (raw or "").strip()
        m = re.search(r"\[[\s\S]*\]", raw)
        if not m:
            return []
        data = json.loads(m.group(0))
        if not isinstance(data, list):
            return []
        out = []
        for item in data[:5]:
            if isinstance(item, str) and 3 <= len(item.strip()) <= 300:
                out.append(item.strip())
        return out
    except Exception:
        return []




def migrate_memory(from_user_id: str, to_user_id: str) -> dict:
    """Mescla fatos de from → to (sem duplicar texto). Usado ao unificar login Google."""
    src = _safe_user_id(from_user_id)
    dst = _safe_user_id(to_user_id)
    if src == dst:
        return {"ok": True, "merged": 0, "from": src, "to": dst}
    source = MemoryStore(user_id=src)
    target = MemoryStore(user_id=dst)
    merged = 0
    with _lock:
        src_data = source._read()
        dst_data = target._read()
        existing = {
            (f.get("text") or "").strip().lower()
            for f in dst_data.get("facts", [])
            if isinstance(f, dict)
        }
        facts = list(dst_data.get("facts") or [])
        for f in src_data.get("facts") or []:
            if not isinstance(f, dict):
                continue
            text = (f.get("text") or "").strip()
            if not text:
                continue
            key = text.lower()
            if key in existing:
                continue
            existing.add(key)
            item = dict(f)
            item.setdefault("id", str(int(datetime.now().timestamp() * 1000)) + f"_{merged}")
            item["source"] = item.get("source") or "migrate"
            facts.append(item)
            merged += 1
        if len(facts) > MemoryStore.MAX_FACTS:
            facts = facts[-MemoryStore.MAX_FACTS :]
        dst_data["facts"] = facts
        target._write(dst_data)
    return {"ok": True, "merged": merged, "from": src, "to": dst}


def get_store(user_id: Optional[str] = None) -> MemoryStore:
    return MemoryStore(user_id=user_id)


# compat: store default (rotas antigas)
memory_store = MemoryStore(user_id="default")