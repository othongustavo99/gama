"""Regressão: qualquer modo deve completar /chat sem NameError.

Testa o fluxo real de NDJSON da rota, substituindo apenas o provedor pago e
componentes não relacionados. Não exige rede, chave de API ou Volume real.
"""
import asyncio
import importlib
import json
import unittest
from unittest.mock import AsyncMock, patch

from app.models import ChatRequest, ChatMessage

chat_route = importlib.import_module("app.routes.chat")


class ChatModeStreamingRegressionTests(unittest.IsolatedAsyncioTestCase):
    async def test_saudacoes_e_modos_finalizam_stream_sem_erro(self):
        for mode, expected_model in (
            ("conversar", "openai/gpt-5.4-mini"),
            ("trabalhar", "z-ai/glm-5.3-flash"),
            ("oficina_imagem", "openai/gpt-5.4-mini"),
            ("oficina_video", "openai/gpt-5.4-mini"),
        ):
            with self.subTest(mode=mode):
                invoked = []

                async def fake_stream_chat(*, model, messages):
                    invoked.append(model)
                    yield json.dumps({"message": {"role": "assistant", "content": "Tudo ótimo!"}, "done": False}) + "\n"
                    yield json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}) + "\n"

                request = ChatRequest(
                    model="openai/gpt-5.4-mini",
                    chat_mode=mode,
                    messages=[ChatMessage(role="user", content="Tudo bem?")],
                    auto_memory=False,
                    plugins={"memory": False, "web_search": False},
                )
                with (
                    patch.object(chat_route.app_settings, "AGENT_TOOLS_ENABLED", False),
                    patch.object(chat_route.gama, "build_messages", new=AsyncMock(
                        return_value=([{"role": "user", "content": "Tudo bem?"}], None, None, []))),
                    patch.object(chat_route.llm, "stream_chat", new=fake_stream_chat),
                    patch.object(chat_route, "schedule_summary_refresh", return_value=None),
                ):
                    response = await chat_route.chat(request, user_id="test-user-mode")
                    events = []
                    async for chunk in response.body_iterator:
                        events.extend(json.loads(line) for line in chunk.splitlines() if line.strip())

                self.assertFalse(any("error" in event for event in events), events)
                self.assertTrue(any(event.get("done") is True for event in events), events)
                self.assertTrue(any("Tudo ótimo" in (event.get("message") or {}).get("content", "") for event in events), events)
                self.assertEqual(invoked, [expected_model])


if __name__ == "__main__":
    unittest.main()
