"""Cliente LLM do Gama — OpenRouter (padrão) ou Ollama (legado).  (v2)

Novidades:
- aplica MAX_OUTPUT_TOKENS (na v1 o limite existia só no módulo morto core/llm.py);
- cliente HTTP compartilhado (reaproveita conexões) e retry com backoff em
  429/5xx/falha de rede (só antes do primeiro token);
- erros com mensagem pública amigável (sem vazar corpo da resposta do provedor);
- um único evento `done` por resposta (a v1 enviava dois);
- streaming com *tool calling* (`stream_events`) para o agente.

O stream legado continua no formato Ollama NDJSON para o app Flutter:
  {"message":{"role":"assistant","content":"..."},"done":false}
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import re
import time
from typing import Any, AsyncIterator, Iterable, Optional

import httpx

from .config import settings

logger = logging.getLogger(__name__)

_GAMA_IMAGE_RE = re.compile(r"\[gama_image\][\s\S]*?\[/gama_image\]", re.I)
_MAX_MSG_CHARS = 12_000
_MAX_TOTAL_INPUT_CHARS = 280_000  # folga vs limite 400k tokens do OpenRouter
_RETRY_STATUS = {408, 425, 429, 500, 502, 503, 504}


# --------------------------------------------------------------------------- erros

class LLMError(RuntimeError):
    """Erro do provedor. `public_message` é seguro para mostrar ao usuário."""

    def __init__(self, status: Optional[int], public_message: str, detail: str = ""):
        super().__init__(public_message)
        self.status = status
        self.public_message = public_message
        self.detail = detail

    @classmethod
    def from_response(cls, status: int, body: str) -> "LLMError":
        low = (body or "").lower()
        if status in (401, 403):
            msg = "A chave do provedor de IA é inválida ou foi revogada."
        elif status == 402:
            msg = "O provedor de IA está sem crédito no momento."
        elif status == 404:
            msg = "O modelo de IA escolhido não está disponível."
        elif status in (408, 504):
            msg = "O provedor de IA demorou demais para responder."
        elif status == 429:
            msg = "O provedor de IA está com muitas requisições. Tente de novo em instantes."
        elif status >= 500:
            msg = "O provedor de IA está instável agora. Tente de novo em instantes."
        elif status == 400 and ("context" in low or "too long" in low or "maximum" in low):
            msg = "A conversa ficou grande demais para o modelo. Comece uma nova conversa ou resuma o pedido."
        else:
            msg = "O provedor de IA recusou o pedido."
        return cls(status, msg, (body or "")[:500])

    @property
    def tools_unsupported(self) -> bool:
        low = self.detail.lower()
        return self.status in (400, 404, 422) and ("tool" in low or "function" in low)


def _retry_delay(attempt: int, retry_after: Optional[str]) -> float:
    if retry_after:
        try:
            return min(float(retry_after), 8.0)
        except ValueError:
            pass
    return min(0.8 * (2 ** attempt) + random.random() * 0.3, 6.0)


_TRANSIENT = (
    httpx.ConnectError,
    httpx.ConnectTimeout,
    httpx.ReadTimeout,
    httpx.RemoteProtocolError,
    httpx.PoolTimeout,
)


# --------------------------------------------------------------------------- mensagens

def _strip_heavy_content(text: str) -> str:
    if not text:
        return ""
    t = _GAMA_IMAGE_RE.sub("\n[imagem gerada anteriormente]\n", text)
    if len(t) > _MAX_MSG_CHARS:
        t = t[:_MAX_MSG_CHARS] + "\n\n…[cortado para caber no contexto]"
    return t


def _budget_messages(messages: list[dict]) -> list[dict]:
    """Mantém mensagens recentes dentro do orçamento de caracteres.

    A última mensagem do usuário (código colado) usa teto maior e
    tem prioridade no orçamento.
    """
    last_user = -1
    for i in range(len(messages) - 1, -1, -1):
        if (messages[i].get("role") or "") == "user":
            last_user = i
            break

    def clip_last(txt: str) -> str:
        if "[gama_image]" in txt:
            txt = _GAMA_IMAGE_RE.sub("\n[imagem gerada anteriormente]\n", txt)
        if len(txt) > 100_000:
            txt = txt[:100_000] + "\n…[código cortado no limite]"
        return txt

    cleaned: list[dict] = []
    for i, m in enumerate(messages):
        role = m.get("role") or "user"
        content = m.get("content")
        is_last_user = i == last_user
        if isinstance(content, list):
            parts = []
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text":
                    txt = str(part.get("text") or "")
                    txt = clip_last(txt) if is_last_user else _strip_heavy_content(txt)
                    parts.append({"type": "text", "text": txt})
                else:
                    parts.append(part)
            cleaned.append({"role": role, "content": parts or ""})
        else:
            txt = str(content or "")
            cleaned.append({"role": role, "content": clip_last(txt) if is_last_user else _strip_heavy_content(txt)})

    out: list[dict] = []
    total = 0
    for idx in range(len(cleaned) - 1, -1, -1):
        m = cleaned[idx]
        c = m.get("content")
        if isinstance(c, list):
            size = sum(len(str(p.get("text") or "")) for p in c if isinstance(p, dict))
        else:
            size = len(str(c or ""))
        is_last = m.get("role") == "user" and not any(x.get("role") == "user" for x in cleaned[idx + 1:])
        if out and total + size > _MAX_TOTAL_INPUT_CHARS and not is_last:
            break
        out.insert(0, m)
        total += size
    return out


# --------------------------------------------------------------------------- SSE (puro, testável)

def parse_sse_line(line: str) -> Any:
    """Converte uma linha SSE em dict. Retorna None (ignorar) ou "DONE"."""
    line = (line or "").strip()
    if not line or line.startswith(":"):
        return None
    if line.startswith("data:"):
        line = line[5:].strip()
    if not line:
        return None
    if line == "[DONE]":
        return "DONE"
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return None


async def iter_openai_events(lines: AsyncIterator[str]) -> AsyncIterator[dict]:
    """Linhas SSE (OpenAI-compatível) -> eventos:

    {"type":"token","text":str}
    {"type":"tool_calls","calls":[{"id","name","arguments"}]}
    {"type":"usage","usage":dict}
    {"type":"finish","reason":str|None}
    """
    acc: dict[int, dict] = {}
    emitted_tools = False
    finish_reason: Optional[str] = None

    def flush_tools() -> Optional[dict]:
        nonlocal emitted_tools
        if not acc or emitted_tools:
            return None
        emitted_tools = True
        calls = []
        for idx in sorted(acc):
            c = acc[idx]
            if c["name"]:
                calls.append({"id": c["id"] or f"call_{idx}", "name": c["name"], "arguments": c["arguments"] or "{}"})
        return {"type": "tool_calls", "calls": calls} if calls else None

    async for raw in lines:
        data = parse_sse_line(raw)
        if data is None:
            continue
        if data == "DONE":
            break
        if not isinstance(data, dict):
            continue
        if data.get("error"):
            err = data["error"]
            msg = err.get("message") if isinstance(err, dict) else str(err)
            raise LLMError(None, "O provedor de IA interrompeu a resposta.", str(msg)[:300])
        if data.get("usage"):
            yield {"type": "usage", "usage": data["usage"]}
        choices = data.get("choices") or []
        if not choices:
            continue
        choice = choices[0]
        delta = choice.get("delta") or {}
        text = delta.get("content") or ""
        if text:
            yield {"type": "token", "text": text}
        for tc in delta.get("tool_calls") or []:
            idx = int(tc.get("index", 0))
            slot = acc.setdefault(idx, {"id": "", "name": "", "arguments": ""})
            if tc.get("id"):
                slot["id"] = tc["id"]
            fn = tc.get("function") or {}
            if fn.get("name"):
                slot["name"] = fn["name"]
            if fn.get("arguments"):
                slot["arguments"] += fn["arguments"]
        if choice.get("finish_reason"):
            finish_reason = choice["finish_reason"]
            ev = flush_tools()
            if ev:
                yield ev

    ev = flush_tools()
    if ev:
        yield ev
    yield {"type": "finish", "reason": finish_reason}


def _ndjson(content: str, done: bool) -> str:
    return json.dumps({"message": {"role": "assistant", "content": content}, "done": done}, ensure_ascii=False) + "\n"


# --------------------------------------------------------------------------- cliente

class LLMClient:
    provider = settings.PROVIDER

    def __init__(self) -> None:
        self._client: Optional[httpx.AsyncClient] = None
        self._health: tuple[float, bool] = (0.0, False)

    # ---- infraestrutura ----------------------------------------------------
    def _http(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                timeout=httpx.Timeout(connect=20.0, read=None, write=60.0, pool=20.0),
                limits=httpx.Limits(max_connections=50, max_keepalive_connections=10),
            )
        return self._client

    async def aclose(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()

    def _openrouter_headers(self) -> dict[str, str]:
        h = {
            "Authorization": f"Bearer {settings.OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
        }
        referer = (getattr(settings, "OPENROUTER_HTTP_REFERER", None) or "").strip()
        title = (getattr(settings, "OPENROUTER_APP_TITLE", None) or "").strip()
        if referer:
            h["HTTP-Referer"] = referer
        if title:
            h["X-Title"] = title
        return h

    async def health(self) -> bool:
        """Saúde do provedor, com cache (probe do Docker/Railway não gasta chamada externa a cada 15 s)."""
        ts, value = self._health
        if time.monotonic() - ts < settings.HEALTH_CACHE_SECONDS:
            return value
        ok = False
        try:
            if settings.PROVIDER == "openrouter":
                if settings.OPENROUTER_API_KEY:
                    r = await self._http().get(
                        f"{settings.OPENROUTER_BASE_URL}/models",
                        headers=self._openrouter_headers(),
                        timeout=10.0,
                    )
                    ok = r.is_success
            else:
                r = await self._http().get(f"{settings.OLLAMA_URL}/api/tags", timeout=5.0)
                ok = r.is_success
        except Exception:  # noqa: BLE001
            ok = False
        self._health = (time.monotonic(), ok)
        return ok

    async def list_models(self) -> list[str]:
        return list(settings.allowed_models)

    def resolve_model(self, requested: str | None) -> str:
        model = (requested or "").strip()
        if not model:
            return settings.default_model
        allowed = set(settings.allowed_models)
        vision = (getattr(settings, "VISION_MODEL", None) or "").strip()
        if model in allowed or (vision and model == vision):
            return model
        return settings.default_model

    # ---- preparo -----------------------------------------------------------
    def prepare_messages(self, messages: list[dict]) -> list[dict]:
        has_mm = any(isinstance(m.get("content"), list) for m in messages)
        return _budget_messages(self._normalize_messages(messages, keep_multimodal=has_mm))

    def _payload(self, model: str, msgs: list[dict], *, stream: bool, max_tokens: Optional[int],
                 temperature: Optional[float], tools: Optional[list[dict]] = None) -> dict:
        payload: dict = {
            "model": model,
            "messages": msgs,
            "stream": stream,
            "temperature": settings.TEMPERATURE if temperature is None else temperature,
            "max_tokens": max(1, int(max_tokens or settings.MAX_OUTPUT_TOKENS)),
        }
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        return payload

    # ---- chamada única -----------------------------------------------------
    async def chat_once(
        self,
        model: str,
        messages: list[dict],
        *,
        timeout: float = 120.0,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> str:
        model = self.resolve_model(model)
        msgs = self.prepare_messages(messages)

        if settings.PROVIDER == "openrouter":
            if not settings.OPENROUTER_API_KEY:
                raise LLMError(None, "A chave do provedor de IA não está configurada no servidor.")
            payload = self._payload(model, msgs, stream=False, max_tokens=max_tokens, temperature=temperature)
            url, headers = f"{settings.OPENROUTER_BASE_URL}/chat/completions", self._openrouter_headers()
        else:
            payload = {"model": model, "messages": msgs, "stream": False, "keep_alive": settings.OLLAMA_KEEP_ALIVE}
            url, headers = f"{settings.OLLAMA_URL}/api/chat", {}

        retries = settings.LLM_RETRIES
        for attempt in range(retries + 1):
            try:
                r = await self._http().post(url, headers=headers, json=payload, timeout=timeout)
            except _TRANSIENT as exc:
                if attempt >= retries:
                    raise LLMError(None, "Não consegui falar com o provedor de IA agora.", str(exc)) from exc
                await asyncio.sleep(_retry_delay(attempt, None))
                continue
            if r.status_code >= 400:
                if r.status_code in _RETRY_STATUS and attempt < retries:
                    await asyncio.sleep(_retry_delay(attempt, r.headers.get("retry-after")))
                    continue
                raise LLMError.from_response(r.status_code, r.text)
            data = r.json()
            if settings.PROVIDER == "openrouter":
                choices = data.get("choices") or []
                return str((choices[0].get("message") or {}).get("content") or "").strip() if choices else ""
            return str((data.get("message") or {}).get("content") or "").strip()
        return ""

    # ---- streaming com eventos (agente) -------------------------------------
    async def stream_events(
        self,
        model: str,
        messages: list[dict],
        *,
        tools: Optional[list[dict]] = None,
        raw: bool = False,
        max_tokens: Optional[int] = None,
        temperature: Optional[float] = None,
    ) -> AsyncIterator[dict]:
        """Eventos de token/tool_calls/usage/finish (somente OpenRouter).

        raw=True: `messages` já está pronto (inclui roles `tool`), não normaliza.
        """
        if settings.PROVIDER != "openrouter":
            raise LLMError(None, "Ferramentas exigem o provedor OpenRouter.")
        if not settings.OPENROUTER_API_KEY:
            raise LLMError(None, "A chave do provedor de IA não está configurada no servidor.")
        model = self.resolve_model(model)
        msgs = messages if raw else self.prepare_messages(messages)
        payload = self._payload(model, msgs, stream=True, max_tokens=max_tokens, temperature=temperature, tools=tools)
        retries = settings.LLM_RETRIES
        started = False

        for attempt in range(retries + 1):
            try:
                async with self._http().stream(
                    "POST",
                    f"{settings.OPENROUTER_BASE_URL}/chat/completions",
                    headers=self._openrouter_headers(),
                    json=payload,
                ) as response:
                    if response.status_code >= 400:
                        body = (await response.aread()).decode(errors="replace")
                        if response.status_code in _RETRY_STATUS and attempt < retries and not started:
                            await asyncio.sleep(_retry_delay(attempt, response.headers.get("retry-after")))
                            continue
                        raise LLMError.from_response(response.status_code, body)
                    async for ev in iter_openai_events(response.aiter_lines()):
                        if ev["type"] == "token":
                            started = True
                        elif ev["type"] == "usage":
                            logger.info("llm usage model=%s %s", model, ev["usage"])
                        yield ev
                    return
            except _TRANSIENT as exc:
                if started or attempt >= retries:
                    raise LLMError(None, "A conexão com o provedor de IA caiu.", str(exc)) from exc
                await asyncio.sleep(_retry_delay(attempt, None))

    # ---- streaming legado (NDJSON estilo Ollama, usado pelo app) ---------------
    async def stream_chat(self, model: str, messages: list[dict]) -> AsyncIterator[str]:
        model = self.resolve_model(model)

        if settings.PROVIDER == "openrouter":
            async for ev in self.stream_events(model, messages):
                if ev["type"] == "token":
                    yield _ndjson(ev["text"], False)
            yield _ndjson("", True)
            return

        msgs = self.prepare_messages(messages)
        payload = {"model": model, "messages": msgs, "stream": True, "keep_alive": settings.OLLAMA_KEEP_ALIVE}
        async with self._http().stream("POST", f"{settings.OLLAMA_URL}/api/chat", json=payload) as response:
            if response.status_code >= 400:
                raise LLMError.from_response(response.status_code, (await response.aread()).decode(errors="replace"))
            async for line in response.aiter_lines():
                if line:
                    yield line + "\n"

    # ---- utilidades ----------------------------------------------------------
    @staticmethod
    def _normalize_messages(messages: list[dict], *, keep_multimodal: bool = False) -> list[dict]:
        """Normaliza mensagens. Se keep_multimodal=True, preserva content em lista (visão)."""
        output: list[dict] = []
        for message in messages:
            role = message.get("role") or "user"
            if role not in {"system", "user", "assistant"}:
                role = "user"
            content = message.get("content")
            if isinstance(content, list):
                if keep_multimodal:
                    parts = []
                    for part in content:
                        if not isinstance(part, dict):
                            continue
                        ptype = part.get("type")
                        if ptype == "text":
                            parts.append({"type": "text", "text": str(part.get("text") or "")})
                        elif ptype == "image_url":
                            parts.append(part)
                    content = parts if parts else ""
                else:
                    text_parts = [
                        str(part.get("text", ""))
                        for part in content
                        if isinstance(part, dict) and part.get("type") == "text"
                    ]
                    content = " ".join(p for p in text_parts if p).strip()
            if content is None:
                content = ""
            if not isinstance(content, list):
                content = str(content)
            output.append({"role": role, "content": content})
        return output

    @staticmethod
    def inject_images(messages: list[dict], images, *, provider: str) -> list[dict]:
        """Injeta imagens no último user message (formato OpenAI multimodal)."""
        if not images:
            return messages
        result = [dict(message) for message in messages]

        image_parts: list[dict] = []
        for img in images[:3]:
            data = (img.get("data") or "").strip()
            if not data:
                continue
            mime = (img.get("mime") or "image/jpeg").strip()
            url = data if data.startswith("data:") else f"data:{mime};base64,{data}"
            image_parts.append({"type": "image_url", "image_url": {"url": url}})

        if not image_parts:
            return messages

        for i in range(len(result) - 1, -1, -1):
            if result[i].get("role") != "user":
                continue
            current = result[i].get("content") or ""
            if isinstance(current, list):
                text = " ".join(
                    str(p.get("text", "")) for p in current if isinstance(p, dict) and p.get("type") == "text"
                ).strip()
            else:
                text = str(current).strip()

            names = ", ".join(str(img.get("name") or "imagem") for img in images[:3])
            if not text:
                text = (
                    f"Analise a(s) imagem(ns) anexada(s): {names}. "
                    "Descreva o que vê com detalhe e responda ao pedido do usuário."
                )
            parts: list[dict] = [{"type": "text", "text": text}]
            parts.extend(image_parts)
            result[i]["content"] = parts
            break

        return result


llm = LLMClient()
ollama = llm
