"""Seleção e orçamento de contexto enviados aos provedores LLM.

Os padrões mantêm os valores que o projeto já usava. As variáveis de ambiente
permitem ajustá-los ao modelo contratado sem introduzir uma cota de gastos.
O orçamento é estimado em caracteres de texto; não equivale à contagem de tokens
feita pelo provedor, especialmente em imagens, código e idiomas diferentes.
"""

from __future__ import annotations

import os
import re
from typing import Any

GAMA_IMAGE_RE = re.compile(r"\[gama_image\][\s\S]*?\[/gama_image\]", re.I)


def _env_int(name: str, default: int, *, minimum: int = 1, maximum: int = 5_000_000) -> int:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw.strip())
    except (TypeError, ValueError):
        return default
    return max(minimum, min(value, maximum))


# Mantém o comportamento atual por padrão; operadores podem ampliar os valores.
MAX_MESSAGE_CHARS = _env_int("GAMA_LLM_MAX_MESSAGE_CHARS", 12_000, minimum=256)
MAX_LAST_USER_CHARS = _env_int("GAMA_LLM_MAX_LAST_USER_CHARS", 100_000, minimum=256)
MAX_TOTAL_INPUT_CHARS = _env_int("GAMA_LLM_MAX_TOTAL_INPUT_CHARS", 280_000, minimum=1_024)
CONTEXT_MAX_MESSAGES = _env_int("GAMA_CONTEXT_MAX_MESSAGES", 48, minimum=4, maximum=2_000)
CONTEXT_KEEP_RECENT = _env_int("GAMA_CONTEXT_KEEP_RECENT", 24, minimum=1, maximum=1_000)
CONTEXT_SUMMARY_MAX_CHARS = _env_int("GAMA_CONTEXT_SUMMARY_MAX_CHARS", 2_500, minimum=256)
# Mesmo valor atual (12k) para não elevar o gasto por padrão; pode ser ampliado
# para tarefas com código/documentos longos e permanece abaixo do limite do LLM.
CONTEXT_CURRENT_USER_CHARS = _env_int(
    "GAMA_CONTEXT_MAX_CURRENT_USER_CHARS", MAX_LAST_USER_CHARS, minimum=256
)

_TRUNCATION_MARKER = "\n\n…[trecho omitido para caber no contexto]"
_LAST_USER_MARKER = "\n…[mensagem atual abreviada no limite configurado]"
_TOOL_MARKER = "\n…[resultado antigo de ferramenta abreviado para manter o contexto]"


def _strip_heavy_content(text: str, max_chars: int = MAX_MESSAGE_CHARS) -> str:
    """Reduz marcadores de imagens geradas anteriormente e limita texto antigo."""
    if not text:
        return ""
    text = GAMA_IMAGE_RE.sub("\n[imagem gerada anteriormente]\n", text)
    if len(text) > max_chars:
        front = max(1, int(max_chars * 0.65))
        back = max(1, max_chars - front)
        text = text[:front] + _TRUNCATION_MARKER + text[-back:]
    return text


def _clip_latest_user(text: str, max_chars: int = MAX_LAST_USER_CHARS) -> str:
    if not text:
        return ""
    text = GAMA_IMAGE_RE.sub("\n[imagem gerada anteriormente]\n", text)
    if len(text) > max_chars:
        text = text[:max_chars] + _LAST_USER_MARKER
    return text


def _text_size(content: Any) -> int:
    """Conta texto, sem contar payloads binários/base64 de imagens."""
    if isinstance(content, list):
        size = 0
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                size += len(str(part.get("text") or ""))
        return size
    return len(str(content or ""))


def budget_messages_with_report(
    messages: list[dict],
    *,
    max_message_chars: int = MAX_MESSAGE_CHARS,
    max_last_user_chars: int = MAX_LAST_USER_CHARS,
    max_total_chars: int = MAX_TOTAL_INPUT_CHARS,
) -> tuple[list[dict], dict[str, int | bool]]:
    """Prepara mensagens e retorna estatísticas sem registrar conteúdo privado.

    Preserva a primeira instrução de sistema e a mensagem atual do usuário como
    prioridades. Contextos de sistema mais recentes são considerados antes do
    histórico antigo. Uma única mensagem antiga grande não elimina os demais
    itens relevantes nem, principalmente, o prompt principal.
    """
    source = list(messages or [])
    last_user = next(
        (i for i in range(len(source) - 1, -1, -1) if (source[i].get("role") or "") == "user"),
        -1,
    )

    cleaned: list[dict] = []
    truncated_count = 0
    for i, original in enumerate(source):
        msg = dict(original)
        role = msg.get("role") or "user"
        content = msg.get("content")
        is_last_user = i == last_user
        if isinstance(content, list):
            parts = []
            for part in content:
                if not isinstance(part, dict):
                    continue
                part_copy = dict(part)
                if part_copy.get("type") == "text":
                    original_text = str(part_copy.get("text") or "")
                    new_text = (
                        _clip_latest_user(original_text, max_last_user_chars)
                        if is_last_user
                        else _strip_heavy_content(original_text, max_message_chars)
                    )
                    if new_text != original_text:
                        truncated_count += 1
                    part_copy["text"] = new_text
                parts.append(part_copy)
            msg["content"] = parts or ""
        else:
            original_text = str(content or "")
            new_text = (
                _clip_latest_user(original_text, max_last_user_chars)
                if is_last_user
                else _strip_heavy_content(original_text, max_message_chars)
            )
            if new_text != original_text:
                truncated_count += 1
            msg["content"] = new_text
        cleaned.append(msg)

    sizes = [_text_size(m.get("content")) for m in cleaned]
    original_chars = sum(_text_size(m.get("content")) for m in source)
    selected: set[int] = set()
    first_system = next(
        (i for i, m in enumerate(cleaned) if (m.get("role") or "") == "system"),
        -1,
    )

    # Instrução principal e pergunta atual são indispensáveis; se elas próprias
    # excederem o orçamento, preservá-las é preferível a enviar um prompt inválido.
    if first_system >= 0:
        selected.add(first_system)
    if last_user >= 0:
        selected.add(last_user)
    total = sum(sizes[i] for i in selected)

    # Contextos adicionais do sistema: o que foi anexado mais recentemente tende
    # a ser o contexto específico desta pergunta (arquivo, web, projeto, memória).
    extra_system = [
        i for i, m in enumerate(cleaned)
        if (m.get("role") or "") == "system" and i not in selected
    ]
    for i in reversed(extra_system):
        if total + sizes[i] <= max_total_chars:
            selected.add(i)
            total += sizes[i]

    # Por fim, inclui histórico recente. Ao encontrar a primeira mensagem que não
    # cabe, para para manter uma janela temporal contígua e previsível.
    history = [
        i for i, m in enumerate(cleaned)
        if (m.get("role") or "") != "system" and i != last_user
    ]
    for i in reversed(history):
        if total + sizes[i] <= max_total_chars:
            selected.add(i)
            total += sizes[i]
        else:
            break

    output = [m for i, m in enumerate(cleaned) if i in selected]
    sent_chars = sum(_text_size(m.get("content")) for m in output)
    report: dict[str, int | bool] = {
        "input_messages": len(source),
        "output_messages": len(output),
        "original_chars": original_chars,
        "sent_chars": sent_chars,
        "dropped_messages": max(0, len(source) - len(output)),
        "truncated_parts": truncated_count,
        "budget_chars": max_total_chars,
        "over_budget_mandatory_context": sent_chars > max_total_chars,
    }
    return output, report


def budget_messages(
    messages: list[dict],
    *,
    max_message_chars: int = MAX_MESSAGE_CHARS,
    max_last_user_chars: int = MAX_LAST_USER_CHARS,
    max_total_chars: int = MAX_TOTAL_INPUT_CHARS,
) -> list[dict]:
    """Compatibilidade simples: devolve apenas as mensagens já selecionadas."""
    return budget_messages_with_report(
        messages,
        max_message_chars=max_message_chars,
        max_last_user_chars=max_last_user_chars,
        max_total_chars=max_total_chars,
    )[0]


def budget_raw_tool_messages(
    messages: list[dict], *, max_total_chars: int = MAX_TOTAL_INPUT_CHARS
) -> list[dict]:
    """Limita crescimento de respostas de ferramentas preservando o protocolo.

    Ao contrário do caminho de chat normal, esse caminho deve conservar roles
    `tool`, `tool_call_id` e `tool_calls`. Se novas respostas de ferramentas
    ultrapassarem o orçamento, abrevia primeiro os resultados de ferramentas mais
    antigos, sem remover as mensagens que fecham o ciclo de tool calling.
    """
    result = [dict(m) for m in (messages or [])]
    total = sum(_text_size(m.get("content")) for m in result)
    excess = total - max_total_chars
    if excess <= 0:
        return result

    for msg in result:
        if excess <= 0:
            break
        if (msg.get("role") or "") != "tool":
            continue
        content = msg.get("content")
        if not isinstance(content, str) or not content:
            continue
        # Mantém pelo menos um marcador para deixar explícito que houve retorno.
        removable = max(0, len(content) - min(len(_TOOL_MARKER), len(content)))
        cut = min(excess, removable)
        if cut:
            new_size = len(content) - cut
            marker = _TOOL_MARKER[:new_size] if new_size <= len(_TOOL_MARKER) else _TOOL_MARKER
            keep = max(0, new_size - len(marker))
            msg["content"] = content[:keep] + marker
            excess = max(0, excess - (len(content) - len(msg["content"])))
    return result
