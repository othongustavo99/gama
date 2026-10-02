
"""
Cliente de LLM da Gama.

Provider único:
  - ollama → Ollama hospedado no Railway

Modelos disponíveis:
  - qwen2.5-coder:14b → padrão
  - phi4-mini         → secundário

O stream devolve NDJSON no formato que o Flutter já espera:
{"message":{"content":"..."},"done":false/true}
"""

from __future__ import annotations

from typing import AsyncIterator

import httpx

from .config import settings


class LLMClient:
    def __init__(self) -> None:
        # A Gama usa somente Ollama.
        self.provider = "ollama"

    # ------------------------------------------------------------------
    # HEALTH
    # ------------------------------------------------------------------

    async def health(self) -> bool:
        return await self._ollama_health()

    async def _ollama_health(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                response = await client.get(
                    f"{settings.OLLAMA_URL}/api/tags"
                )

                return response.is_success

        except Exception:
            return False

    # ------------------------------------------------------------------
    # MODELOS
    # ------------------------------------------------------------------

    async def list_models(self) -> list[str]:
        """
        Retorna somente os modelos permitidos pela Gama.

        O Railway/Ollama pode ter outros modelos instalados,
        mas a Gama só disponibiliza estes dois para seleção.
        """

        return [
            "qwen2.5-coder:14b",
            "phi4-mini",
        ]

    def resolve_model(self, requested: str | None) -> str:
        """
        Define o modelo utilizado.

        Se o Flutter não enviar um modelo válido,
        Qwen 2.5 Coder 14B será utilizado.
        """

        model = (requested or "").strip()

        allowed_models = {
            "qwen2.5-coder:14b",
            "phi4-mini",
        }

        if model in allowed_models:
            return model

        return "qwen2.5-coder:14b"

    # ------------------------------------------------------------------
    # CHAT SEM STREAM
    # ------------------------------------------------------------------

    async def chat_once(
        self,
        model: str,
        messages: list[dict],
        *,
        timeout: float = 120.0,
    ) -> str:

        model = self.resolve_model(model)

        return await self._ollama_chat_once(
            model,
            messages,
            timeout=timeout,
        )

    async def _ollama_chat_once(
        self,
        model: str,
        messages: list[dict],
        *,
        timeout: float,
    ) -> str:

        payload = {
            "model": model,
            "messages": messages,
            "stream": False,
        }

        async with httpx.AsyncClient(timeout=timeout) as client:

            response = await client.post(
                f"{settings.OLLAMA_URL}/api/chat",
                json=payload,
            )

            response.raise_for_status()

            data = response.json()

            message = data.get("message") or {}

            return (message.get("content") or "").strip()

    # ------------------------------------------------------------------
    # STREAM
    # ------------------------------------------------------------------

    async def stream_chat(
        self,
        model: str,
        messages: list[dict],
    ) -> AsyncIterator[str]:

        model = self.resolve_model(model)

        async for line in self._ollama_stream(
            model,
            messages,
        ):
            yield line

    async def _ollama_stream(
        self,
        model: str,
        messages: list[dict],
    ) -> AsyncIterator[str]:

        payload = {
            "model": model,
            "messages": messages,
            "stream": True,
        }

        client = httpx.AsyncClient(timeout=None)

        try:

            request = client.build_request(
                "POST",
                f"{settings.OLLAMA_URL}/api/chat",
                json=payload,
            )

            response = await client.send(
                request,
                stream=True,
            )

            response.raise_for_status()

            async for line in response.aiter_lines():

                if line:
                    yield line + "\n"

        finally:

            await client.aclose()

    # ------------------------------------------------------------------
    # NORMALIZAÇÃO DE MENSAGENS
    # ------------------------------------------------------------------

    def _normalize_messages(
        self,
        messages: list[dict],
    ) -> list[dict]:

        output = []

        for message in messages:

            role = message.get("role") or "user"

            content = message.get("content")

            if content is None:
                content = ""

            if role not in (
                "system",
                "user",
                "assistant",
            ):
                role = "user"

            output.append(
                {
                    "role": role,
                    "content": content,
                }
            )

        return output

    # ------------------------------------------------------------------
    # IMAGENS
    # ------------------------------------------------------------------

    @staticmethod
    def inject_images(
        messages: list[dict],
        images,
        *,
        provider: str,
    ) -> list[dict]:

        """
        Adiciona imagens à última mensagem do usuário.

        Ollama utiliza:

        {
            "role": "user",
            "content": "...",
            "images": [
                "base64..."
            ]
        }
        """

        if not images:
            return messages

        messages_copy = [
            dict(message)
            for message in messages
        ]

        # Procura a última mensagem do usuário.
        index = None

        for i in range(
            len(messages_copy) - 1,
            -1,
            -1,
        ):

            if messages_copy[i].get("role") == "user":
                index = i
                break

        # Se não existir mensagem do usuário,
        # cria uma.
        if index is None:

            messages_copy.append(
                {
                    "role": "user",
                    "content": "",
                }
            )

            index = len(messages_copy) - 1

        raw_content = (
            messages_copy[index].get("content")
            or ""
        )

        # Extrai o texto caso o conteúdo
        # já esteja no formato multimodal.
        if isinstance(raw_content, list):

            text = " ".join(
                part.get("text", "")
                for part in raw_content
                if (
                    isinstance(part, dict)
                    and part.get("type") == "text"
                )
            ).strip()

        else:

            text = str(raw_content).strip()

        if not text:

            text = (
                "Analise a(s) imagem(ns) anexada(s) "
                "e responda com base no que foi observado."
            )

        # --------------------------------------------------------------
        # OLLAMA
        # --------------------------------------------------------------

        messages_copy[index]["content"] = text

        messages_copy[index]["images"] = [
            (image.get("data") or "").strip()
            for image in images
            if (image.get("data") or "").strip()
        ]

        return messages_copy


# ----------------------------------------------------------------------
# INSTÂNCIA GLOBAL
# ----------------------------------------------------------------------

llm = LLMClient()

# Mantém compatibilidade com imports antigos.
ollama = llm

