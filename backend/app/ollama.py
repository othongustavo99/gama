"""Adaptador de compatibilidade para o cliente Ollama do Gama."""

from __future__ import annotations

from .llm import llm

ollama = llm


class OllamaClient:
    async def health(self) -> bool:
        return await llm.health()

    async def list_models(self) -> list[str]:
        return await llm.list_models()

    def resolve_model(self, model: str | None) -> str:
        return llm.resolve_model(model)

    async def chat_once(
        self,
        model: str,
        messages: list[dict],
        *,
        timeout: float = 180.0,
    ) -> str:
        return await llm.chat_once(model, messages, timeout=timeout)

    async def stream_chat(self, model: str, messages: list[dict]):
        async for line in llm.stream_chat(model, messages):
            yield line
