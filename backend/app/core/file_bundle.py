"""Geração de pacotes de arquivos (`[[GAMA_FILES]]`) resistente a respostas cortadas.

Problemas tratados:
- A resposta bate no limite de saída (`finish_reason == "length"`) antes do
  marcador de fechamento. Solução: pedir a continuação do ponto exato, até
  MAX_CONTINUATIONS vezes.
- Projetos grandes exigem muitos arquivos completos em uma resposta só. Solução:
  geração em dois passos (lista de caminhos; depois um arquivo por chamada).

Este módulo não conhece FastAPI nem o provedor de IA: recebe `chat_fn`, uma função
async que recebe `messages` e devolve {"text", "finish_reason", "usage"}.
"""

from __future__ import annotations

import asyncio
import re
from typing import Any, Awaitable, Callable

ChatFn = Callable[[list[dict]], Awaitable[dict[str, Any]]]

CLOSE_MARKER = "[[/GAMA_FILES]]"
MAX_CONTINUATIONS = 3  # era 2; mais uma tentativa contra respostas cortadas
MAX_PLAN_FILES = 20  # era 12; refactors médios cabem sem estourar custo demais
PER_FILE_CONCURRENCY = 3
_TAIL_CHARS = 14_000

_CONTINUE_PROMPT = (
    "Sua resposta anterior foi cortada no limite de tamanho. Continue EXATAMENTE de onde parou: "
    "não repita o que já foi escrito, não recomece o bloco, não adicione texto novo. "
    f"Quando terminar o conteúdo, feche com {CLOSE_MARKER}."
)
_PLAN_PROMPT = (
    "Liste SOMENTE os caminhos dos arquivos que precisam ser criados ou alterados para atender ao pedido, "
    "um por linha, dentro de [[GAMA_PLAN]] e [[/GAMA_PLAN]]. Não escreva código nesta resposta.\n"
    "Formato:\n[[GAMA_PLAN]]\ncaminho/relativo.ext\n[[/GAMA_PLAN]]"
)
_FILE_PROMPT = (
    "Gere SOMENTE o arquivo `{path}`, completo, sem outros arquivos e sem reticências ou trechos omitidos.\n"
    "Formato obrigatório (cabeçalho path: obrigatório; conteúdo integral entre quatro crases):\n"
    "[[GAMA_FILES]]\npath: {path}\n````\nconteúdo integral\n````\n[[/GAMA_FILES]]\n"
    "Não invente o arquivo se não houver evidência no contexto; nesse caso responda só:\n"
    "[[GAMA_FILES]]\npath: {path}\n````\n# arquivo não disponível no contexto\n````\n[[/GAMA_FILES]]"
)

_PLAN_RE = re.compile(r"\[\[GAMA_PLAN\]\](.*?)(?:\[\[/GAMA_PLAN\]\]|\Z)", re.DOTALL)
_INNER_RE = re.compile(r"\[\[GAMA_FILES\]\](.*?)(?:\[\[/GAMA_FILES\]\]|\Z)", re.DOTALL)


async def chat_with_continuation(chat_fn: ChatFn, messages: list[dict]) -> dict[str, Any]:
    """Chama o modelo e, se a saída foi cortada pelo limite, pede a continuação."""
    parts: list[str] = []
    current = list(messages)
    last: dict[str, Any] = {}
    continuations = 0
    for continuations in range(MAX_CONTINUATIONS + 1):
        last = await chat_fn(current)
        parts.append(str(last.get("text") or ""))
        full = "".join(parts)
        if CLOSE_MARKER in full or last.get("finish_reason") != "length":
            break
        if continuations == MAX_CONTINUATIONS:
            break
        current = list(messages) + [
            {"role": "assistant", "content": full[-_TAIL_CHARS:]},
            {"role": "user", "content": _CONTINUE_PROMPT},
        ]
    return {
        "text": "".join(parts),
        "finish_reason": last.get("finish_reason"),
        "usage": last.get("usage") or {},
        "continuations": continuations,
    }


def parse_plan(text: str) -> list[str]:
    """Extrai caminhos válidos do bloco [[GAMA_PLAN]]. Rejeita caminhos absolutos ou com `..`."""
    match = _PLAN_RE.search(text or "")
    if not match:
        return []
    paths: list[str] = []
    for raw in match.group(1).splitlines():
        path = raw.strip().strip("`\"-* ").replace("\\", "/")
        if not path or path.startswith("/") or ".." in path.split("/") or ":" in path.split("/")[0]:
            continue
        if path not in paths:
            paths.append(path)
    return paths[:MAX_PLAN_FILES]


def assemble_bundle(file_responses: list[str]) -> str:
    """Junta respostas de um arquivo cada num único bloco [[GAMA_FILES]]."""
    bodies: list[str] = []
    for response in file_responses:
        for match in _INNER_RE.finditer(response or ""):
            body = match.group(1).strip("\n")
            if body.strip():
                bodies.append(body)
    if not bodies:
        return ""
    return "[[GAMA_FILES]]\n" + "\n".join(bodies) + f"\n{CLOSE_MARKER}"


def _complete_file_response(text: str, path: str) -> bool:
    """A named, fenced, non-placeholder file with closed outer markers."""
    if "[[GAMA_FILES]]" not in text or CLOSE_MARKER not in text:
        return False
    body = _INNER_RE.search(text)
    if not body:
        return False
    # Paths must come from the path header, not from explanatory prose.
    path_line = re.compile(r"(?im)^\s*path\s*:\s*`?" + re.escape(path) + r"`?\s*$")
    match = path_line.search(body.group(1))
    if not match:
        return False
    after = body.group(1)[match.end():]
    open_fence = re.match(r"^\s*(`{3,}|~{3,})[^\r\n]*\n", after)
    if not open_fence:
        return False
    fence = open_fence.group(1)
    closing = re.search(r"(?m)^\s*" + re.escape(fence[0]) +
                        r"{" + str(len(fence)) + r",}\s*$", after[open_fence.end():])
    if not closing:
        return False
    content = after[open_fence.end():][:closing.start()].strip()
    if not content:
        return False
    if re.match(r"(?i)^(?:#\s*)?(?:arquivo não disponível|arquivo nao disponivel|placeholder|TODO:? preencher)\b", content):
        return False
    return True


async def generate_files_per_file(
    chat_fn: ChatFn,
    base_messages: list[dict],
    progress_callback: Callable[[int, int, str], None] | None = None,
) -> dict[str, Any]:
    """Dois passos: lista os caminhos e gera cada arquivo em sua própria chamada.

    Retorna {"bundle": texto para o parser, "paths": [...], "failed": [...]}.
    """
    plan_result = await chat_with_continuation(chat_fn, base_messages + [{"role": "user", "content": _PLAN_PROMPT}])
    paths = parse_plan(plan_result["text"])
    if not paths:
        return {"bundle": "", "paths": [], "failed": [], "plan_finish_reason": plan_result.get("finish_reason")}

    semaphore = asyncio.Semaphore(PER_FILE_CONCURRENCY)
    failed: list[str] = []
    completed = 0

    async def _one(path: str) -> str:
        nonlocal completed
        async with semaphore:
            try:
                prompt = {"role": "user", "content": _FILE_PROMPT.format(path=path)}
                result = await chat_with_continuation(chat_fn, base_messages + [prompt])
                text = result["text"] or ""
                if not _complete_file_response(text, path):
                    # Retry only the defective file rather than regenerating
                    # the entire multi-file archive and losing good results.
                    retry = await chat_with_continuation(chat_fn, base_messages + [
                        prompt,
                        {"role": "assistant", "content": text[-4000:]},
                        {"role": "user", "content": (
                            f"O arquivo {path} veio incompleto ou sem delimitadores corretos. "
                            "Gere novamente APENAS este arquivo, com path:, abertura/fechamento "
                            "da cerca de código e [[/GAMA_FILES]]. Sem placeholders."
                        )},
                    ])
                    text = retry["text"] or ""
                if not _complete_file_response(text, path):
                    failed.append(path)
                    return ""
                return text
            finally:
                completed += 1
                if progress_callback:
                    progress_callback(completed, len(paths), path)

    responses = await asyncio.gather(*(_one(p) for p in paths))
    return {
        "bundle": assemble_bundle(responses),
        "paths": paths,
        "failed": failed,
        "plan_finish_reason": plan_result.get("finish_reason"),
    }
