import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.core.context_budget import (  # noqa: E402
    MAX_MESSAGE_CHARS,
    MAX_LAST_USER_CHARS,
    MAX_TOTAL_INPUT_CHARS,
    budget_messages,
    budget_messages_with_report,
    budget_raw_tool_messages,
)


class ContextBudgetTests(unittest.TestCase):
    def test_defaults_keep_current_context_limits(self):
        # Configuração padrão deliberadamente preservada: sem nova cota de gastos.
        expected = {
            "GAMA_LLM_MAX_MESSAGE_CHARS": (MAX_MESSAGE_CHARS, 12_000),
            "GAMA_LLM_MAX_LAST_USER_CHARS": (MAX_LAST_USER_CHARS, 100_000),
            "GAMA_LLM_MAX_TOTAL_INPUT_CHARS": (MAX_TOTAL_INPUT_CHARS, 280_000),
        }
        for name, (actual, default) in expected.items():
            if name not in os.environ:
                self.assertEqual(actual, default)
            else:
                self.assertGreaterEqual(actual, 1_024 if "TOTAL" in name else 256)

    def test_preserves_main_system_prompt_and_latest_user(self):
        messages = [
            {"role": "system", "content": "INSTRUÇÃO PRINCIPAL"},
            {"role": "user", "content": "histórico antigo " + "x" * 200},
            {"role": "assistant", "content": "resposta antiga " + "y" * 200},
            {"role": "user", "content": "PERGUNTA ATUAL"},
        ]
        result, report = budget_messages_with_report(
            messages, max_message_chars=300, max_last_user_chars=300, max_total_chars=45
        )
        self.assertEqual(result[0]["content"], "INSTRUÇÃO PRINCIPAL")
        self.assertEqual(result[-1]["content"], "PERGUNTA ATUAL")
        self.assertGreaterEqual(report["dropped_messages"], 1)
        self.assertFalse(report["over_budget_mandatory_context"])

    def test_latest_system_context_is_prioritized_over_old_history(self):
        messages = [
            {"role": "system", "content": "PROMPT BASE"},
            {"role": "user", "content": "histórico " + "h" * 200},
            {"role": "assistant", "content": "resposta " + "a" * 200},
            {"role": "system", "content": "CONTEXTO DE CÓDIGO IMPORTANTE"},
            {"role": "user", "content": "Corrija o arquivo atual"},
        ]
        result = budget_messages(messages, max_message_chars=300, max_last_user_chars=300, max_total_chars=100)
        contents = [m["content"] for m in result]
        self.assertIn("PROMPT BASE", contents)
        self.assertIn("CONTEXTO DE CÓDIGO IMPORTANTE", contents)
        self.assertIn("Corrija o arquivo atual", contents)

    def test_long_latest_user_message_has_separate_configurable_limit(self):
        long_text = "c" * 300
        result = budget_messages(
            [{"role": "system", "content": "system"}, {"role": "user", "content": long_text}],
            max_message_chars=20,
            max_last_user_chars=250,
            max_total_chars=400,
        )
        latest = result[-1]["content"]
        self.assertTrue(latest.startswith("c" * 100))
        self.assertIn("mensagem atual abreviada", latest)
        self.assertGreater(len(latest), 20)

    def test_code_analyzer_system_source_not_clipped_at_12000_chars(self):
        code = "[Code Analyzer — contexto selecionado]\n" + "a" * 17000 + "MIDDLE_SOURCE_MARKER" + "b" * 17000
        messages = [
            {"role": "system", "content": "PROMPT PRINCIPAL"},
            {"role": "system", "content": code},
            {"role": "user", "content": "Corrija os arquivos"},
        ]
        result, report = budget_messages_with_report(
            messages, max_message_chars=12000, max_last_user_chars=100000,
            max_total_chars=80000,
        )
        self.assertIn("MIDDLE_SOURCE_MARKER", result[1]["content"])
        self.assertEqual(result[1]["content"], code)
        self.assertEqual(report["truncated_parts"], 0)
        self.assertLessEqual(report["sent_chars"], 80000)

    def test_other_long_system_text_keeps_regular_limit(self):
        messages = [
            {"role": "system", "content": "PROMPT PRINCIPAL"},
            {"role": "system", "content": "outro contexto " + "X" * 40000},
            {"role": "user", "content": "oi"},
        ]
        result, report = budget_messages_with_report(
            messages, max_message_chars=12000, max_total_chars=80000,
        )
        self.assertLess(len(result[1]["content"]), 13000)
        self.assertGreater(report["truncated_parts"], 0)

    def test_raw_tool_budget_preserves_tool_protocol(self):
        messages = [
            {"role": "system", "content": "root"},
            {"role": "user", "content": "question"},
            {"role": "assistant", "content": None, "tool_calls": [{"id": "call-1"}]},
            {"role": "tool", "tool_call_id": "call-1", "content": "resultado " + "r" * 800},
        ]
        result = budget_raw_tool_messages(messages, max_total_chars=100)
        self.assertEqual(result[2]["tool_calls"], [{"id": "call-1"}])
        self.assertEqual(result[3]["role"], "tool")
        self.assertEqual(result[3]["tool_call_id"], "call-1")
        self.assertIn("abreviado", result[3]["content"])
        self.assertLessEqual(sum(len(str(m.get("content") or "")) for m in result), 100)


if __name__ == "__main__":
    unittest.main()
