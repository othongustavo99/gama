"""
Cliente unificado de LLM.

Providers:
  - ollama      → API local do Ollama
  - openrouter  → OpenAI-compatible (https://openrouter.ai)
  - groq        → OpenAI-compatible (https://console.groq.com)

O stream sempre devolve NDJSON no formato que o Flutter já espera
(estilo Ollama): {"message":{"content":"..."},"done":false/true}
"""

from __future__ import annotations

import json
from typing import AsyncIterator, List

import httpx

from .config import settings


class LLMClient:
    def __init__(self) -> None:
        self.provider = settings.PROVIDER

    # ------------------------------------------------------------------ health
    async def health(self) -> bool:
        if self.provider == "ollama":
            return await self._ollama_health()
        if self.provider == "openrouter":
            return bool(settings.OPENROUTER_API_KEY)
        if self.provider == "groq":
            return bool(settings.GROQ_API_KEY)
        return False

    async def _ollama_health(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                r = await client.get(f"{settings.OLLAMA_URL}/api/tags")
                return r.is_success
        except Exception:
            return False

    # -------------------------------------------------------------- list models
    async def list_models(self) -> list[str]:
        if self.provider == "ollama":
            return await self._ollama_list_models()
        if self.provider == "openrouter":
            return [
                settings.OPENROUTER_DEFAULT_MODEL,
                "openai/gpt-4o-mini",
                "anthropic/claude-3.5-haiku",
                "google/gemini-2.0-flash-001",
                "meta-llama/llama-3.3-70b-instruct",
            ]
        if self.provider == "groq":
            return [
                settings.GROQ_DEFAULT_MODEL,
                "llama-3.3-70b-versatile",
                "llama-3.1-8b-instant",
                "mixtral-8x7b-32768",
                "gemma2-9b-it",
            ]
        return []

    async def _ollama_list_models(self) -> list[str]:
        async with httpx.AsyncClient(timeout=10.0) as client:
            r = await client.get(f"{settings.OLLAMA_URL}/api/tags")
            r.raise_for_status()
            models = r.json().get("models", [])
            return [m.get("name", "") for m in models if m.get("name")]

    def resolve_model(self, requested: str | None) -> str:
        """Se o app mandar modelo local/vazio no provider cloud, usa o default."""
        name = (requested or "").strip()
        if self.provider == "ollama":
            return name or "phi4-mini"
        if self.provider == "openrouter":
            # OpenRouter usa ids tipo "openai/gpt-4o-mini"
            if not name or "/" not in name:
                return settings.OPENROUTER_DEFAULT_MODEL
            return name
        if self.provider == "groq":
            groq_ok = {
                "llama-3.3-70b-versatile",
                "llama-3.1-8b-instant",
                "mixtral-8x7b-32768",
                "gemma2-9b-it",
            }
            if name in groq_ok:
                return name
            return settings.GROQ_DEFAULT_MODEL
        return name or "phi4-mini"

    # --------------------------------------------------------------- chat once
    async def chat_once(
        self,
        model: str,
        messages: list[dict],
        *,
        timeout: float = 120.0,
    ) -> str:
        model = self.resolve_model(model)
        if self.provider == "ollama":
            return await self._ollama_chat_once(model, messages, timeout=timeout)
        return await self._openai_chat_once(model, messages, timeout=timeout)

    async def _ollama_chat_once(
        self, model: str, messages: list[dict], *, timeout: float
    ) -> str:
        payload = {"model": model, "messages": messages, "stream": False}
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(
                f"{settings.OLLAMA_URL}/api/chat",
                json=payload,
            )
            r.raise_for_status()
            msg = r.json().get("message") or {}
            return (msg.get("content") or "").strip()

    async def _openai_chat_once(
        self, model: str, messages: list[dict], *, timeout: float
    ) -> str:
        url, headers = self._openai_endpoint()
        payload = {
            "model": model,
            "messages": self._normalize_messages(messages),
            "stream": False,
        }
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(url, headers=headers, json=payload)
            r.raise_for_status()
            data = r.json()
            choices = data.get("choices") or []
            if not choices:
                return ""
            return (choices[0].get("message") or {}).get("content") or ""

    # ----------------------------------------------------------------- stream
    async def stream_chat(
        self,
        model: str,
        messages: list[dict],
    ) -> AsyncIterator[str]:
        model = self.resolve_model(model)
        if self.provider == "ollama":
            async for line in self._ollama_stream(model, messages):
                yield line
        else:
            async for line in self._openai_stream(model, messages):
                yield line

    async def _ollama_stream(
        self, model: str, messages: list[dict]
    ) -> AsyncIterator[str]:
        payload = {"model": model, "messages": messages, "stream": True}
        client = httpx.AsyncClient(timeout=None)
        try:
            response = await client.send(
                client.build_request(
                    "POST",
                    f"{settings.OLLAMA_URL}/api/chat",
                    json=payload,
                ),
                stream=True,
            )
            response.raise_for_status()
            async for line in response.aiter_lines():
                if line:
                    yield line + "\n"
        finally:
            await client.aclose()

    async def _openai_stream(
        self, model: str, messages: list[dict]
    ) -> AsyncIterator[str]:
        """
        Lê SSE OpenAI e reemite no formato Ollama NDJSON
        para o Flutter não precisar mudar.
        """
        url, headers = self._openai_endpoint()
        payload = {
            "model": model,
            "messages": self._normalize_messages(messages),
            "stream": True,
        }

        client = httpx.AsyncClient(timeout=None)
        try:
            response = await client.send(
                client.build_request(
                    "POST",
                    url,
                    headers=headers,
                    json=payload,
                ),
                stream=True,
            )
            response.raise_for_status()

            async for line in response.aiter_lines():
                if not line:
                    continue
                if line.startswith(":"):
                    continue  # keep-alive SSE
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    yield json.dumps(
                        {"message": {"role": "assistant", "content": ""}, "done": True}
                    ) + "\n"
                    break
                try:
                    obj = json.loads(data)
                except json.JSONDecodeError:
                    continue
                choices = obj.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                content = delta.get("content") or ""
                finish = choices[0].get("finish_reason")
                if content:
                    yield json.dumps(
                        {
                            "message": {"role": "assistant", "content": content},
                            "done": False,
                        },
                        ensure_ascii=False,
                    ) + "\n"
                if finish:
                    yield json.dumps(
                        {
                            "message": {"role": "assistant", "content": ""},
                            "done": True,
                        }
                    ) + "\n"
        finally:
            await client.aclose()

    # ---------------------------------------------------------------- helpers
    def _openai_endpoint(self) -> tuple[str, dict]:
        if self.provider == "openrouter":
            key = settings.OPENROUTER_API_KEY
            if not key:
                raise RuntimeError(
                    "OPENROUTER_API_KEY não configurada. "
                    "Defina a variável de ambiente no deploy."
                )
            headers = {
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
                "HTTP-Referer": settings.APP_URL,
                "X-Title": settings.APP_NAME,
            }
            return f"{settings.OPENROUTER_BASE_URL}/chat/completions", headers

        if self.provider == "groq":
            key = settings.GROQ_API_KEY
            if not key:
                raise RuntimeError(
                    "GROQ_API_KEY não configurada. "
                    "Defina a variável de ambiente no deploy."
                )
            headers = {
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
            }
            return f"{settings.GROQ_BASE_URL}/chat/completions", headers

        raise RuntimeError(f"Provider desconhecido: {self.provider}")

    def _normalize_messages(self, messages: list[dict]) -> List[dict]:
        """Garante role/content no formato OpenAI (texto ou multimodal)."""
        out = []
        for m in messages:
            role = m.get("role") or "user"
            content = m.get("content")
            if content is None:
                content = ""
            if role not in ("system", "user", "assistant"):
                role = "user"
            # content pode ser str OU lista [{type, text/image_url}, ...]
            out.append({"role": role, "content": content})
        return out

    @staticmethod
    def inject_images(
        messages: list[dict],
        images,
        *,
        provider: str,
    ) -> list[dict]:
        """
        Anexa imagens à última mensagem do usuário.
        - openrouter/groq: content multimodal (image_url data URI)
        - ollama: campo images[] com base64 puro
        """
        if not images:
            return messages

        msgs = [dict(m) for m in messages]
        # acha última user
        idx = None
        for i in range(len(msgs) - 1, -1, -1):
            if msgs[i].get("role") == "user":
                idx = i
                break
        if idx is None:
            msgs.append({"role": "user", "content": ""})
            idx = len(msgs) - 1

        raw_content = msgs[idx].get("content") or ""
        if isinstance(raw_content, list):
            text = " ".join(
                p.get("text", "")
                for p in raw_content
                if isinstance(p, dict) and p.get("type") == "text"
            ).strip()
        else:
            text = str(raw_content).strip()

        if not text:
            text = "Analise a(s) imagem(ns) anexada(s) e responda com base no que vir."

        if provider == "ollama":
            msgs[idx]["content"] = text
            # Ollama: lista de base64 sem data: prefix
            msgs[idx]["images"] = [
                (img.get("data") or "").strip()
                for img in images
                if (img.get("data") or "").strip()
            ]
        else:
            parts = [{"type": "text", "text": text}]
            for img in images:
                data = (img.get("data") or "").strip()
                if not data:
                    continue
                mime = img.get("mime") or "image/jpeg"
                parts.append(
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:{mime};base64,{data}"},
                    }
                )
            msgs[idx]["content"] = parts

        return msgs


# Instância global (mesmo padrão do ollama.py antigo)
llm = LLMClient()

# Alias para não quebrar imports antigos
ollama = llm
