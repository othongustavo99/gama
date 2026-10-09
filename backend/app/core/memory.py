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
import uuid
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


_LABEL_RE = re.compile(
    r"^(Nome|Idade|Nascimento|Natural de|Mora em|Estado civil|Profissão|Cor favorita|"
    r"Esposa|Esposo|Marido|Mulher|Namorado|Namorada|Filho|Filha|Irmão|Irmã|Mãe|Pai|"
    r"Empresa|Projeto|App|Aplicativo|Stack|Linguagem|Framework|Time)\s*:",
    re.IGNORECASE,
)


def _label_of(text: str) -> Optional[str]:
    m = _LABEL_RE.match((text or "").strip())
    return m.group(1).lower() if m else None


def _new_id() -> str:
    return uuid.uuid4().hex


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
            facts = data.get("facts")
            data["facts"] = [f for f in facts if isinstance(f, dict)] if isinstance(facts, list) else []
            data["user_id"] = self.user_id
            return data
        except Exception:
            return {"facts": [], "user_id": self.user_id}

    def _write(self, data: dict) -> None:
        """Escrita atômica: nunca deixa o JSON pela metade (o que zerava a memória)."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data["user_id"] = self.user_id
        tmp = self.path.with_suffix(".json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            try:
                os.fsync(f.fileno())
            except OSError:
                pass
        os.replace(tmp, self.path)

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
            label = _label_of(text)

            for f in facts:
                ftext = f.get("text", "")
                if ftext.lower() == normalized:
                    return f
                # mesmo rótulo (Nome:, Idade:, Mora em:...) → atualiza em vez de duplicar
                if label and _label_of(ftext) == label:
                    f["text"] = text
                    f["source"] = source
                    f["updated_at"] = _utc_now()
                    data["facts"] = facts
                    self._write(data)
                    return f
                # quase duplicata (só para textos longos o bastante)
                fl = ftext.lower()
                if len(fl) >= 8 and len(normalized) >= 8 and (normalized in fl or fl in normalized):
                    if len(text) > len(ftext):
                        f["text"] = text
                        f["source"] = source
                        f["updated_at"] = _utc_now()
                        data["facts"] = facts
                        self._write(data)
                    return f

            item = {
                "id": _new_id(),
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
        texts = [str(f.get("text", "")).strip() for f in facts if str(f.get("text", "")).strip()]
        if not texts:
            return ""
        lines = [
            "MEMÓRIA DE LONGO PRAZO — FATOS SOBRE O USUÁRIO COM QUEM VOCÊ FALA AGORA",
            "Estes fatos foram gravados e estão DISPONÍVEIS neste momento. São verdadeiros.",
            "REGRAS:",
            "- Quando o usuário perguntar sobre si mesmo (nome, idade, onde mora, gostos, "
            "o que pediu para você lembrar), responda diretamente com base nesta lista.",
            "- NUNCA diga que não sabe, que não tem memória ou que não foi informada de algo que "
            "está listado aqui.",
            "- Só diga que ainda não sabe se a informação realmente NÃO estiver na lista; "
            "nesse caso, ofereça-se para guardar.",
            "- Se algo parecer desatualizado, peça confirmação.",
            "",
            "FATOS:",
        ]
        for t in texts:
            lines.append(f"- {t}")
        return "\n".join(lines)


# --------------------------------------------------------------------------- extract

_QUESTION_START = re.compile(
    r"^\s*(?:qual|quais|quem|quando|onde|como|quanto|quantos|quantas|por\s*que|porque|"
    r"o\s+que|voc[eê]\s+sabe|vc\s+sabe|sabe\s+(?:meu|minha|qual|quem)|me\s+diz|me\s+diga|"
    r"lembra\s+(?:do|da|qual|quem|o\s+que)|voc[eê]\s+lembra)\b",
    re.IGNORECASE,
)

_EXPLICIT_REMEMBER = [
    re.compile(
        r"\b(?:lembre(?:-se)?|lembra|grave|anote|salve|salva|guarde|guarda|memorize)\s+"
        r"(?:isso\s+|isto\s+|ai\s+|aí\s+)?(?:na\s+mem[oó]ria\s+)?(?:que\s+)?(.+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:coloca|coloque|ponha|p[oõ]e|guarda|guarde)\s+na\s+mem[oó]ria\s+(?:que\s+)?(.+)",
        re.IGNORECASE,
    ),
    re.compile(r"\b(?:remember(?:\s+that)?|note\s+that)\s+(.+)", re.IGNORECASE),
]

_STOP = r"[^\n.!?;]+"


def _clean(v: str) -> str:
    v = re.sub(r"\s+", " ", (v or "")).strip(" ,.;:!?\"'")
    # corta cláusulas encadeadas: "Gustavo e eu moro em SP" → "Gustavo"
    v = re.split(r"\s+e\s+(?:eu|tenho|moro|sou|trabalho|me)\b", v, maxsplit=1, flags=re.I)[0]
    v = re.split(r",\s*(?:eu|tenho|moro|sou|trabalho)\b", v, maxsplit=1, flags=re.I)[0]
    return v.strip(" ,.;:!?")


def _titlecase_name(v: str) -> str:
    return " ".join(w[:1].upper() + w[1:] if w.islower() else w for w in v.split())


# (regex, formatador) — ordem importa; cada um gera um fato rotulado
_STRUCTURED = [
    (re.compile(r"\bmeu\s+nome(?:\s+completo)?\s+(?:é|e)\s+(" + _STOP + ")", re.I),
     lambda m: "Nome: " + _titlecase_name(_clean(m.group(1)))),
    (re.compile(r"\b(?:me\s+chamo|pode\s+me\s+chamar\s+de|(?:eu\s+)?me\s+chamam\s+de|meu\s+apelido\s+(?:é|e))\s+(" + _STOP + ")", re.I),
     lambda m: "Nome: " + _titlecase_name(_clean(m.group(1)))),
    (re.compile(r"\b(?:tenho|estou\s+com)\s+(\d{1,3})\s+anos\b", re.I),
     lambda m: f"Idade: {m.group(1)} anos"),
    (re.compile(r"\bminha\s+idade\s+(?:é|e)\s+(\d{1,3})\b", re.I),
     lambda m: f"Idade: {m.group(1)} anos"),
    (re.compile(r"\b(?:nasci|nascido|nascida)\s+(?:em|no\s+dia|no\s+ano|na)\s+(" + _STOP + ")", re.I),
     lambda m: "Nascimento: " + _clean(m.group(1))),
    (re.compile(r"\b(?:sou\s+(?:de|natural\s+de)|natural\s+de)\s+(" + _STOP + ")", re.I),
     lambda m: "Natural de: " + _clean(m.group(1))),
    (re.compile(r"\b(?:moro|vivo|resido)\s+(?:em|no|na|nos|nas)\s+(" + _STOP + ")", re.I),
     lambda m: "Mora em: " + _clean(m.group(1))),
    (re.compile(r"\b(?:sou|estou)\s+(casad[oa]|solteir[oa]|divorciad[oa]|vi[uú]v[oa]|namorando|noiv[oa])\b", re.I),
     lambda m: "Estado civil: " + m.group(1).lower()),
    (re.compile(r"\bminha\s+profiss[aã]o\s+(?:é|e)\s+(" + _STOP + ")", re.I),
     lambda m: "Profissão: " + _clean(m.group(1))),
    (re.compile(r"\btrabalho\s+(?:como|de|com|na|no)\s+(" + _STOP + ")", re.I),
     lambda m: "Profissão: " + _clean(m.group(1))),
    (re.compile(
        r"\bsou\s+(?:um\s+|uma\s+)?((?:desenvolvedor|programador|engenheir|m[eé]dic|professor|advogad|"
        r"designer|analista|estudante|arquitet|contador|enfermeir|psic[oó]log|empreendedor|"
        r"administrador|empres[aá]ri)\w*(?:\s+" + _STOP + ")?)", re.I),
     lambda m: "Profissão: " + _clean(m.group(1))),
    (re.compile(r"\b(?:minha|meu)\s+cor\s+favorita\s+(?:é|e)\s+(" + _STOP + ")", re.I),
     lambda m: "Cor favorita: " + _clean(m.group(1))),
    (re.compile(
        r"\b(?:minha|meu)\s+(esposa|esposo|marido|mulher|namorad[oa]|filh[oa]|irm[ãa]o?|m[ãa]e|pai)"
        r"\s+(?:se\s+chama|chama-se|(?:é|e)\s+(?:o|a)?)\s+(" + _STOP + ")", re.I),
     lambda m: m.group(1).capitalize() + ": " + _titlecase_name(_clean(m.group(2)))),
    (re.compile(
        r"\b(?:minha|meu)\s+(empresa|projeto|app|aplicativo|stack|linguagem|framework|time)"
        r"\s+(?:se\s+chama|chama-se|(?:é|e))\s+(" + _STOP + ")", re.I),
     lambda m: m.group(1).capitalize() + ": " + _clean(m.group(2))),
    (re.compile(r"\b(?:n[aã]o\s+gosto\s+d[eoa]s?)\s+(" + _STOP + ")", re.I),
     lambda m: "Não gosta de: " + _clean(m.group(1))),
    (re.compile(r"(?<!n[aã]o )\bgosto\s+(?:muito\s+)?d[eoa]s?\s+(" + _STOP + ")", re.I),
     lambda m: "Gosta de: " + _clean(m.group(1))),
    (re.compile(r"\bprefiro\s+(" + _STOP + ")", re.I),
     lambda m: "Prefere: " + _clean(m.group(1))),
    (re.compile(r"\bodeio\s+(" + _STOP + ")", re.I),
     lambda m: "Odeia: " + _clean(m.group(1))),
]


def _structured_facts(text: str) -> List[str]:
    out: List[str] = []
    for rx, fmt in _STRUCTURED:
        m = rx.search(text)
        if not m:
            continue
        try:
            fact = fmt(m).strip()
        except Exception:
            continue
        body = fact.split(":", 1)[-1].strip()
        if 1 <= len(body) <= 200 and fact not in out:
            out.append(fact)
    return out


def try_extract_memories(user_text: str) -> List[str]:
    """Extração rápida por regex (síncrona, no início do turno).

    Sempre devolve fatos AUTOCONTIDOS e rotulados ("Nome: Gustavo", "Idade: 33 anos"),
    para o modelo saber o que cada valor significa.
    """
    if not isinstance(user_text, str):
        return []
    text = user_text.strip()
    if len(text) < 6 or len(text) > 800:
        return []
    if text.count("```") >= 2 or text.startswith("Anexos para análise"):
        return []
    # perguntas nunca viram memória ("qual é o meu nome?")
    if _QUESTION_START.match(text) or text.rstrip().endswith("?"):
        return []

    # 1) pedido explícito: "lembre que ...", "grave na memória ..."
    for rx in _EXPLICIT_REMEMBER:
        m = rx.search(text)
        if m:
            inner = re.sub(r"^(?:na\s+mem[oó]ria\s+)", "", m.group(1).strip(), flags=re.I)
            inner = re.sub(r"\s+", " ", inner).strip().rstrip(".!")
            if not inner:
                return []
            structured = _structured_facts(inner)
            if structured:
                return structured
            return [inner[:300]] if 3 <= len(inner) else []

    # 2) declarações espontâneas
    return _structured_facts(text)


def try_extract_memory(user_text: str) -> Optional[str]:
    """Compat: primeiro fato extraído (ou None)."""
    facts = try_extract_memories(user_text)
    return facts[0] if facts else None


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
            item.setdefault("id", _new_id())
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