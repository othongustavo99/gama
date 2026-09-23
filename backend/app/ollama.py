import httpx

from .config import settings


class OllamaClient:
    async def health(self) -> bool:
        try:
            async with httpx.AsyncClient(
                timeout=5.0
            ) as client:
                response = await client.get(
                    f"{settings.OLLAMA_URL}/api/tags"
                )

                return response.is_success

        except Exception:
            return False

    async def list_models(self) -> list[str]:
        async with httpx.AsyncClient(
            timeout=10.0
        ) as client:
            response = await client.get(
                f"{settings.OLLAMA_URL}/api/tags"
            )

            response.raise_for_status()

            data = response.json()

            models = data.get("models", [])

            return [
                model.get("name", "")
                for model in models
                if model.get("name")
            ]

    async def stream_chat(
        self,
        model: str,
        messages: list[dict],
    ):
        """
        Envia a conversa para o Ollama e repassa
        cada objeto NDJSON individualmente.

        É importante adicionar '\\n' ao final de cada
        linha para que o Flutter consiga separar os
        objetos JSON do streaming.
        """

        payload = {
            "model": model,
            "messages": messages,
            "stream": True,
        }

        client = httpx.AsyncClient(
            timeout=None,
        )

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
                if not line:
                    continue

                # IMPORTANTE:
                # O Flutter espera NDJSON, portanto cada
                # objeto precisa terminar com uma quebra
                # de linha.
                yield line + "\n"

        finally:
            await client.aclose()


ollama = OllamaClient()