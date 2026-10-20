import asyncio
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ["DATA_DIR"] = tempfile.mkdtemp()

from app.core import context as ctx  # noqa: E402


def convo(n):
    return [{"role": "user" if i % 2 == 0 else "assistant", "content": f"mensagem {i} sobre flutter e dart"} for i in range(n)]


class FakeLLM:
    def __init__(self):
        self.calls = 0

    async def chat_once(self, **kw):
        self.calls += 1
        return "- Usuário desenvolve o app Gama em Flutter\n- Decidiu usar FastAPI no backend e OpenRouter como provedor"


class ContextTest(unittest.TestCase):
    def test_short_conversation_untouched(self):
        m = ctx.ContextManager()
        out, info = m.prepare_with_summary(convo(10), None)
        self.assertEqual(len(out), 10)
        self.assertFalse(info["needs_refresh"])

    def test_long_conversation_gets_summary_and_recent(self):
        m = ctx.ContextManager()
        out, info = m.prepare_with_summary(convo(80), None)
        self.assertEqual(out[0]["role"], "system")
        self.assertEqual(len(out), 1 + m.keep_recent)
        self.assertEqual(out[-1]["content"], "mensagem 79 sobre flutter e dart")
        self.assertTrue(info["needs_refresh"])

    def test_multimodal_content_does_not_crash(self):
        msgs = convo(5) + [{"role": "user", "content": [{"type": "text", "text": "olhe"}, {"type": "image_url", "image_url": {"url": "x"}}]}]
        out, _ = ctx.ContextManager().prepare_with_summary(msgs, None)
        self.assertEqual(out[-1]["content"], "olhe")

    def test_refresh_persists_and_is_reused(self):
        msgs = convo(80)
        llm = FakeLLM()
        ok = asyncio.run(ctx.refresh_summary(llm, "m", msgs, user_id="u1", conversation_id="c1"))
        self.assertTrue(ok)
        state = ctx.SummaryStore("u1").get("c1")
        self.assertIn("FastAPI", state["summary"])
        out, info = ctx.ContextManager().prepare_with_summary(msgs, state)
        self.assertIn("FastAPI", out[0]["content"])
        self.assertFalse(info["needs_refresh"])
        # poucas mensagens novas: não chama o LLM de novo
        again = asyncio.run(ctx.refresh_summary(llm, "m", msgs + convo(2), user_id="u1", conversation_id="c1"))
        self.assertFalse(again)
        self.assertEqual(llm.calls, 1)
        # 10 mensagens novas: re-resume
        more = asyncio.run(ctx.refresh_summary(llm, "m", msgs + convo(12), user_id="u1", conversation_id="c1"))
        self.assertTrue(more)

    def test_history_changed_invalidates_state(self):
        msgs = convo(80)
        asyncio.run(ctx.refresh_summary(FakeLLM(), "m", msgs, user_id="u2", conversation_id="c"))
        state = ctx.SummaryStore("u2").get("c")
        other = [{"role": "user", "content": "começo diferente"}] + convo(79)
        out, info = ctx.ContextManager().prepare_with_summary(other, state)
        self.assertNotIn("FastAPI", out[0]["content"])


if __name__ == "__main__":
    unittest.main()
