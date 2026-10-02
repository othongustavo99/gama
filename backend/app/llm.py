"""Cliente do LLM remoto do Gama.

Arquitetura de produção:
    APK -> FastAPI -> Ollama -> qwen2.5-coder:7b

O Ollama fica no mesmo servidor/rede Docker do backend. O endereço do Ollama
nunca é enviado para o APK.
"""

from __future__ import annotations

from typing import AsyncIterator

import httpx

from .config import settings


class LLMClient:
    provider = settings.PROVIDER

    async def health(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                response = await client.get(f"{settings.OLLAMA_URL}/api/tags")
                return response.is_success
        except Exception:
            return False

    async def list_models(self) -> list[str]:
        """Retorna somente os modelos liberados para o aplicativo."""
        allowed = settings.OLLAMA_MODELS
        try:
            async with httpx.AsyncClient(timeout=8.0) as client:
                response = await client.get(f"{settings.OLLAMA_URL}/api/tags")
                response.raise_for_status()
                installed = {
                    str(item.get("name", "")).strip()
                    for item in response.json().get("models", [])
                    if item.get("name")
                }
        except Exception:
            return allowed

        result = [
            model
            for model in allowed
            if model in installed
            or any(name.startswith(model + ":") for name in installed)
        ]
        return result or allowed

    def resolve_model(self, requested: str | None) -> str:
        model = (requested or "").strip()
        allowed = set(settings.OLLAMA_MODELS)
        if model in allowed:
            return model
        return settings.OLLAMA_DEFAULT_MODEL

    async def chat_once(
        self,
        model: str,
        messages: list[dict],
        *,
        timeout: float = 180.0,
    ) -> str:
        model = self.resolve_model(model)
        payload = {
            "model": model,
            "messages": self._normalize_messages(messages),
            "stream": False,
        }
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.post(
                f"{settings.OLLAMA_URL}/api/chat", json=payload
            )
            response.raise_for_status()
            data = response.json()
            return str((data.get("message") or {}).get("content") or "").strip()

    async def stream_chat(
        self,
        model: str,
        messages: list[dict],
    ) -> AsyncIterator[str]:
        model = self.resolve_model(model)
        payload = {
            "model": model,
            "messages": self._normalize_messages(messages),
            "stream": True,
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

    @staticmethod
    def _normalize_messages(messages: list[dict]) -> list[dict]:
        output: list[dict] = []
        for message in messages:
            role = message.get("role") or "user"
            if role not in {"system", "user", "assistant"}:
                role = "user"
            content = message.get("content")
            if isinstance(content, list):
                # Qwen2.5-Coder 7B é texto. Mantemos somente partes textuais.
                text_parts = [
                    str(part.get("text", ""))
                    for part in content
                    if isinstance(part, dict) and part.get("type") == "text"
                ]
                content = " ".join(p for p in text_parts if p).strip()
            if content is None:
                content = ""
            output.append({"role": role, "content": str(content)})
        return output

    @staticmethod
    def inject_images(messages: list[dict], images, *, provider: str) -> list[dict]:
        """Compatibilidade: o perfil Qwen2.5-Coder 7B é texto/código."""
        if not images:
            return messages
        result = [dict(message) for message in messages]
        for i in range(len(result) - 1, -1, -1):
            if result[i].get("role") == "user":
                current = result[i].get("content") or ""
                if isinstance(current, list):
                    current = " ".join(
                        str(p.get("text", ""))
                        for p in current
                        if isinstance(p, dict) and p.get("type") == "text"
                    )
                result[i]["content"] = (
                    f"{current}\n\n"
                    "[Uma ou mais imagens foram anexadas. Este servidor usa "
                    "Qwen2.5-Coder 7B, que é um modelo de texto/código e não "
                    "faz análise visual direta.]"
                ).strip()
                return result
        return result


llm = LLMClient()
ollama = llm
