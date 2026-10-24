"""Fase 3: testes de continuidade, resumos, memória e roteamento de ferramentas.

Não usa API externa, token pago ou volume real. É seguro rodar com pytest.
"""
import asyncio
import json
import tempfile
import unittest
from unittest.mock import patch

from app.core import context
from app.core.agent import build_tools, is_explanation_only, run_agent
from app.core.memory import fact_supported_by_user, get_store, try_extract_memories, extract_facts_with_llm
from app.core.talk_skill.mode import detect_response_depth, detect_talk_mode
from app.core.talk_skill.pipeline import build_talk_layer


class _SummaryLLM:
    def __init__(self):
        self.requests = []

    async def chat_once(self, **kwargs):
        self.requests.append(kwargs)
        return "- Decisão: manter a Gamma em Flutter e FastAPI.\n- Próxima ação: revisar o chat e testar em Android."


class _AgentLLM:
    def __init__(self, calls):
        self.calls = calls
        self.offered = []

    def prepare_messages(self, messages):
        return list(messages)

    async def stream_events(self, model, messages, tools=None, raw=False):
        self.offered.append({x["function"]["name"] for x in (tools or [])})
        if len(self.offered) == 1:
            yield {"type": "tool_calls", "calls": [
                {"id": "c1", "name": self.calls[0], "arguments": json.dumps(self.calls[1])}
            ]}
        else:
            yield {"type": "token", "text": "Concluído"}


class Phase3TalkTests(unittest.TestCase):
    def test_continua_tarefa_tecnica_com_confirmacao_curta(self):
        history = [
            {"role": "user", "content": "Corrija o erro do projeto Flutter"},
            {"role": "assistant", "content": "Quer que eu mostre a correção completa?"},
            {"role": "user", "content": "sim"},
        ]
        self.assertEqual(detect_talk_mode("sim", messages=history), "focused")
        self.assertEqual(detect_talk_mode("oi", messages=[]), "conversational")

    def test_depth_reacts_to_explicit_request(self):
        self.assertEqual(detect_response_depth("Me explica passo a passo"), "detailed")
        self.assertEqual(detect_response_depth("Resuma isso"), "brief")
        _, detailed = build_talk_layer("Me explica passo a passo")
        self.assertIn("detalhada", detailed)


class Phase3MemoryTests(unittest.TestCase):
    def test_grounding_rejects_made_up_location_and_third_party(self):
        self.assertTrue(fact_supported_by_user("Mora em: Campinas", "eu moro em Campinas"))
        self.assertFalse(fact_supported_by_user("Mora em: Santos", "eu moro em Campinas"))
        self.assertFalse(fact_supported_by_user("Nome: Maria", "O código usa a string Nome: Maria"))
        self.assertFalse(fact_supported_by_user("Mora em: Campinas", "eu moro em Campinas?"))

    def test_examples_are_not_automatically_saved(self):
        self.assertEqual(try_extract_memories("Exemplo: meu nome é Maria"), [])

    def test_llm_memory_extraction_discards_unsupported_claim(self):
        class FakeLLM:
            async def chat_once(self, **kwargs):
                return '[{"text": "Mora em: Santos", "category": "identity"}, {"text": "Mora em: Campinas", "category": "identity"}]'

        facts = asyncio.run(extract_facts_with_llm(
            user_text="eu moro em Campinas", assistant_text="Você mora em Santos?",
            model="m", llm_client=FakeLLM(), existing_facts=[],
        ))
        self.assertEqual([f["text"] for f in facts], ["Mora em: Campinas"])

    def test_relevance_small_memory_does_not_dump_everything(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {"DATA_DIR": tmp}):
            store = get_store("phase3_relevance")
            for i in range(9):
                store.add_fact(f"Gosta de: coisa{i} curiosidade{i}")
            store.add_fact("Projeto: aplicativo de receitas veganas")
            picked = store.select_relevant("quero ideias de receitas veganas")
            self.assertTrue(any("receitas veganas" in f["text"] for f in picked))
            self.assertLess(len(picked), len(store.list_facts()))

    def test_turn_off_memory_removes_memory_tools(self):
        names = {x["function"]["name"] for x in build_tools(memory_enabled=False)}
        self.assertNotIn("remember", names)
        self.assertNotIn("forget_memory", names)
        self.assertIn("get_weather", names)

    def test_memory_tool_disabled_rejects_model_call(self):
        llm = _AgentLLM(("remember", {"fact": "Mora em: Santos"}))
        async def _run():
            return [ev async for ev in run_agent(
                llm, "m", [{"role": "user", "content": "eu moro em Santos"}],
                user_id="phase3_memory_disabled", user_text="eu moro em Santos",
                memory_enabled=False,
            )]
        events = asyncio.run(_run())
        self.assertFalse(any(ev.get("type") == "memory_saved" for ev in events))
        self.assertEqual(get_store("phase3_memory_disabled").list_facts(), [])

    def test_hallucinated_memory_cannot_be_saved(self):
        llm = _AgentLLM(("remember", {"fact": "Mora em: Santos"}))
        async def _run():
            return [ev async for ev in run_agent(
                llm, "m", [{"role": "user", "content": "eu moro em Campinas"}],
                user_id="phase3_memory_grounded", user_text="eu moro em Campinas",
            )]
        events = asyncio.run(_run())
        self.assertFalse(any(ev.get("type") == "memory_saved" for ev in events))
        self.assertEqual(get_store("phase3_memory_grounded").list_facts(), [])


class Phase3ToolTests(unittest.TestCase):
    def test_info_only_does_not_offer_paid_media_or_files(self):
        self.assertTrue(is_explanation_only("Explique como criar um vídeo"))
        self.assertFalse(is_explanation_only("Crie um vídeo"))
        self.assertFalse(is_explanation_only("Explique e depois crie uma imagem"))
        llm = _AgentLLM(("generate_image", {"prompt": "um planeta"}))
        media_calls = []

        async def handler(args):
            media_calls.append(args)
            yield {"type": "result", "content": "Gerada"}

        async def _run():
            return [ev async for ev in run_agent(
                llm, "m", [{"role": "user", "content": "Explique como criar uma imagem"}],
                user_id="phase3_tool", user_text="Explique como criar uma imagem",
                tool_handlers={"generate_image": handler},
            )]
        asyncio.run(_run())
        self.assertNotIn("generate_image", llm.offered[0])
        self.assertFalse(media_calls)


class Phase3ContextTests(unittest.TestCase):
    @staticmethod
    def _messages(n, chars=20):
        return [
            {"role": "user" if i % 2 == 0 else "assistant", "content": f"Turno {i}: " + "a" * chars}
            for i in range(n)
        ]

    def test_local_fallback_keeps_recent_decisions(self):
        msgs = self._messages(60)
        msgs[-1]["content"] = "Nova decisão: manter o desenho minimalista do app"
        result = context.ContextManager._local_summary(msgs, 750)
        self.assertIn("Nova decisão", result)
        self.assertIn("Turno 0", result)
        self.assertIn("intermediárias", result)

    def test_digest_detects_edit_inside_summary(self):
        manager = context.ContextManager(max_messages=12, keep_recent=3)
        original = self._messages(32)
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {"DATA_DIR": tmp}):
            llm = _SummaryLLM()
            self.assertTrue(asyncio.run(context.refresh_summary(
                llm, "m", original, user_id="u", conversation_id="c", manager=manager,
            )))
            state = context.SummaryStore("u").get("c")
            edited = self._messages(32)
            edited[5]["content"] = "Turno cinco foi alterado no histórico"
            output, info = manager.prepare_with_summary(edited, state)
            self.assertEqual(info["covered"], 0)
            self.assertNotIn("Decisão: manter a Gamma", output[0]["content"])

    def test_long_refresh_never_marks_unread_messages_as_summarized(self):
        manager = context.ContextManager(max_messages=10, keep_recent=2)
        messages = self._messages(100, chars=500)
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", {"DATA_DIR": tmp}):
            llm = _SummaryLLM()
            self.assertTrue(asyncio.run(context.refresh_summary(
                llm, "m", messages, user_id="u", conversation_id="c", manager=manager,
            )))
            store = context.SummaryStore("u")
            state = store.get("c")
            self.assertLess(state["covered"], 98)
            self.assertGreater(state["covered"], 0)
            self.assertTrue(asyncio.run(context.refresh_summary(
                llm, "m", messages, user_id="u", conversation_id="c", manager=manager,
            )))
            self.assertGreater(store.get("c")["covered"], state["covered"])


if __name__ == "__main__":
    unittest.main()
