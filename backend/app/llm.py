"""Cliente LLM do Gama — Groq (padrão) ou Ollama.

Streaming sempre no formato Ollama NDJSON para o app Flutter:
  {"message":{"role":"assistant","content":"..."},"done":false}
"""

from __future__ import annotations

import json
import logging
from typing import AsyncIterator

import httpx

from .config import settings

logger = logging.getLogger(__name__)


class LLMClient:
    provider = settings.PROVIDER

    async def health(self) -> bool:
        if settings.PROVIDER == "groq":
            if not settings.GROQ_API_KEY:
                return False
            try:
                async with httpx.AsyncClient(timeout=8.0) as client:
                    r = await client.get(
                        f"{settings.GROQ_BASE_URL}/models",
                        headers=self._groq_headers(),
                    )
                    return r.is_success
            except Exception:
                return False
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                r = await client.get(f"{settings.OLLAMA_URL}/api/tags")
                return r.is_success
        except Exception:
            return False

    async def list_models(self) -> list[str]:
        return list(settings.allowed_models)

    def resolve_model(self, requested: str | None) -> str:
        model = (requested or "").strip()
        if not model:
            return settings.default_model
        allowed = set(settings.allowed_models)
        vision = (getattr(settings, "VISION_MODEL", None) or "").strip()
        # Modelo de visão pode estar fora da lista de chat
        if model in allowed or (vision and model == vision):
            return model
        return settings.default_model

    def _groq_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {settings.GROQ_API_KEY}",
            "Content-Type": "application/json",
        }

    async def chat_once(
        self,
        model: str,
        messages: list[dict],
        *,
        timeout: float = 120.0,
    ) -> str:
        model = self.resolve_model(model)
        has_mm = any(isinstance(m.get("content"), list) for m in messages)
        msgs = self._normalize_messages(messages, keep_multimodal=has_mm)

        if settings.PROVIDER == "groq":
            if not settings.GROQ_API_KEY:
                raise RuntimeError("GROQ_API_KEY não configurada")
            payload = {
                "model": model,
                "messages": msgs,
                "stream": False,
                "temperature": 0.6,
            }
            async with httpx.AsyncClient(timeout=timeout) as client:
                r = await client.post(
                    f"{settings.GROQ_BASE_URL}/chat/completions",
                    headers=self._groq_headers(),
                    json=payload,
                )
                r.raise_for_status()
                data = r.json()
                choices = data.get("choices") or []
                if not choices:
                    return ""
                return str(
                    (choices[0].get("message") or {}).get("content") or ""
                ).strip()

        payload = {
            "model": model,
            "messages": msgs,
            "stream": False,
            "keep_alive": settings.OLLAMA_KEEP_ALIVE,
        }
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(
                f"{settings.OLLAMA_URL}/api/chat", json=payload
            )
            r.raise_for_status()
            data = r.json()
            return str((data.get("message") or {}).get("content") or "").strip()

    async def stream_chat(
        self,
        model: str,
        messages: list[dict],
    ) -> AsyncIterator[str]:
        model = self.resolve_model(model)
        has_mm = any(isinstance(m.get("content"), list) for m in messages)
        msgs = self._normalize_messages(messages, keep_multimodal=has_mm)

        if settings.PROVIDER == "groq":
            async for line in self._stream_groq(model, msgs):
                yield line
            return

        payload = {
            "model": model,
            "messages": msgs,
            "stream": True,
            "keep_alive": settings.OLLAMA_KEEP_ALIVE,
        }
        timeout = httpx.Timeout(connect=15.0, read=None, write=60.0, pool=15.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            async with client.stream(
                "POST", f"{settings.OLLAMA_URL}/api/chat", json=payload
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if line:
                        yield line + "\n"

    async def _stream_groq(
        self, model: str, messages: list[dict]
    ) -> AsyncIterator[str]:
        if not settings.GROQ_API_KEY:
            raise RuntimeError("GROQ_API_KEY não configurada no Railway")

        payload = {
            "model": model,
            "messages": messages,
            "stream": True,
            "temperature": 0.6,
        }
        timeout = httpx.Timeout(connect=20.0, read=None, write=60.0, pool=20.0)

        async with httpx.AsyncClient(timeout=timeout) as client:
            async with client.stream(
                "POST",
                f"{settings.GROQ_BASE_URL}/chat/completions",
                headers=self._groq_headers(),
                json=payload,
            ) as response:
                if response.status_code >= 400:
                    body = await response.aread()
                    raise RuntimeError(
                        f"Groq {response.status_code}: {body.decode(errors='replace')[:400]}"
                    )

                async for line in response.aiter_lines():
                    if not line:
                        continue
                    if line.startswith(":"):
                        continue
                    if line.startswith("data:"):
                        line = line[5:].strip()
                    if not line or line == "[DONE]":
                        if line == "[DONE]":
                            yield json.dumps(
                                {
                                    "message": {
                                        "role": "assistant",
                                        "content": "",
                                    },
                                    "done": True,
                                },
                                ensure_ascii=False,
                            ) + "\n"
                        continue
                    try:
                        data = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    choices = data.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    content = delta.get("content") or ""
                    finish = choices[0].get("finish_reason")
                    if content:
                        yield json.dumps(
                            {
                                "message": {
                                    "role": "assistant",
                                    "content": content,
                                },
                                "done": False,
                            },
                            ensure_ascii=False,
                        ) + "\n"
                    if finish:
                        yield json.dumps(
                            {
                                "message": {
                                    "role": "assistant",
                                    "content": "",
                                },
                                "done": True,
                            },
                            ensure_ascii=False,
                        ) + "\n"

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
                    # Formato OpenAI: [{type:text},{type:image_url}]
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
        """Injeta imagens no último user message.

        Groq (OpenAI-compatible): content multimodal com image_url data-URI.
        Ollama: imagens no campo images (tratado no payload ollama se necessário)
        ou data-URI se o modelo for multimodal OpenAI-like.
        """
        if not images:
            return messages
        result = [dict(message) for message in messages]

        # Monta partes de imagem (máx. 3 no Groq)
        image_parts: list[dict] = []
        for img in images[:3]:
            data = (img.get("data") or "").strip()
            if not data:
                continue
            mime = (img.get("mime") or "image/jpeg").strip()
            if data.startswith("data:"):
                url = data
            else:
                url = f"data:{mime};base64,{data}"
            image_parts.append(
                {
                    "type": "image_url",
                    "image_url": {"url": url},
                }
            )

        if not image_parts:
            return messages

        for i in range(len(result) - 1, -1, -1):
            if result[i].get("role") != "user":
                continue
            current = result[i].get("content") or ""
            if isinstance(current, list):
                text = " ".join(
                    str(p.get("text", ""))
                    for p in current
                    if isinstance(p, dict) and p.get("type") == "text"
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
