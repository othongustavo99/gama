"""Testes do pacote de arquivos resistente a respostas cortadas (stdlib only)."""
import asyncio
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.core import file_bundle as fb  # noqa: E402
from app.core.file_bundle import (  # noqa: E402
    CLOSE_MARKER,
    assemble_bundle,
    chat_with_continuation,
    generate_files_per_file,
    parse_plan,
)


def run(coro):
    return asyncio.run(coro)


class FakeChat:
    """Devolve respostas roteirizadas e registra as mensagens recebidas."""

    def __init__(self, script):
        self.script = list(script)
        self.calls = []

    async def __call__(self, messages):
        self.calls.append(messages)
        item = self.script.pop(0) if self.script else {"text": "", "finish_reason": "stop"}
        return item


class ContinuationTests(unittest.TestCase):
    def test_stops_when_marker_present_and_finish_stop(self):
        chat = FakeChat([{"text": f"[[GAMA_FILES]]\npath: a.py\n````\nx\n````\n{CLOSE_MARKER}", "finish_reason": "stop"}])
        out = run(chat_with_continuation(chat, [{"role": "user", "content": "oi"}]))
        self.assertEqual(out["continuations"], 0)
        self.assertEqual(len(chat.calls), 1)
        self.assertIn(CLOSE_MARKER, out["text"])

    def test_continues_after_length_cut_and_concatenates(self):
        chat = FakeChat([
            {"text": "[[GAMA_FILES]]\npath: a.py\n````\nline1\n", "finish_reason": "length"},
            {"text": f"line2\n````\n{CLOSE_MARKER}", "finish_reason": "stop"},
        ])
        out = run(chat_with_continuation(chat, [{"role": "user", "content": "gera"}]))
        self.assertEqual(out["continuations"], 1)
        self.assertEqual(len(chat.calls), 2)
        self.assertIn("line1", out["text"])
        self.assertIn("line2", out["text"])
        self.assertTrue(out["text"].endswith(CLOSE_MARKER))
        # a continuação carrega o final já escrito e o pedido de continuar
        cont_msgs = chat.calls[1]
        self.assertEqual(cont_msgs[-1]["content"], fb._CONTINUE_PROMPT)
        self.assertIn("line1", cont_msgs[-2]["content"])

    def test_gives_up_after_max_continuations(self):
        chat = FakeChat([{"text": "x", "finish_reason": "length"}] * (fb.MAX_CONTINUATIONS + 3))
        out = run(chat_with_continuation(chat, [{"role": "user", "content": "gera"}]))
        self.assertEqual(len(chat.calls), fb.MAX_CONTINUATIONS + 1)
        self.assertEqual(out["continuations"], fb.MAX_CONTINUATIONS)
        self.assertEqual(out["finish_reason"], "length")


class PlanTests(unittest.TestCase):
    def test_parses_plan_and_rejects_unsafe_paths(self):
        text = (
            "[[GAMA_PLAN]]\n"
            "src/main.py\n"
            "- lib/app.dart\n"
            "`README.md`\n"
            "/etc/passwd\n"
            "../evil.txt\n"
            "C:/windows/x.txt\n"
            "src/main.py\n"
            "[[/GAMA_PLAN]]"
        )
        self.assertEqual(parse_plan(text), ["src/main.py", "lib/app.dart", "README.md"])

    def test_plan_limit_and_missing_block(self):
        many = "[[GAMA_PLAN]]\n" + "\n".join(f"f{i}.py" for i in range(50)) + "\n[[/GAMA_PLAN]]"
        self.assertEqual(len(parse_plan(many)), fb.MAX_PLAN_FILES)
        self.assertEqual(parse_plan("sem bloco nenhum"), [])

    def test_plan_without_closing_marker_still_parses(self):
        self.assertEqual(parse_plan("[[GAMA_PLAN]]\na.py\nb.py"), ["a.py", "b.py"])


class AssembleTests(unittest.TestCase):
    def test_assembles_single_bundle_with_one_close(self):
        r1 = "[[GAMA_FILES]]\npath: a.py\n````\nprint(1)\n````\n[[/GAMA_FILES]]"
        r2 = "[[GAMA_FILES]]\npath: b.py\n````\nprint(2)\n````\n[[/GAMA_FILES]]"
        bundle = assemble_bundle([r1, "lixo sem bloco", r2])
        self.assertEqual(bundle.count("[[GAMA_FILES]]"), 1)
        self.assertEqual(bundle.count(CLOSE_MARKER), 1)
        self.assertIn("path: a.py", bundle)
        self.assertIn("path: b.py", bundle)

    def test_empty_when_nothing_parseable(self):
        self.assertEqual(assemble_bundle(["", "nada"]), "")


class PerFileTests(unittest.TestCase):
    def test_plan_then_one_call_per_file(self):
        def respond(messages):
            last = messages[-1]["content"]
            if last == fb._PLAN_PROMPT:
                return {"text": "[[GAMA_PLAN]]\na.py\nb.py\n[[/GAMA_PLAN]]", "finish_reason": "stop"}
            path = "a.py" if "`a.py`" in last else "b.py"
            body = f"[[GAMA_FILES]]\npath: {path}\n````\ncontent {path}\n````\n{CLOSE_MARKER}"
            return {"text": body, "finish_reason": "stop"}

        calls = []

        async def chat(messages):
            calls.append(messages)
            return respond(messages)

        result = run(generate_files_per_file(chat, [{"role": "user", "content": "pedido"}]))
        self.assertEqual(result["paths"], ["a.py", "b.py"])
        self.assertEqual(result["failed"], [])
        self.assertIn("path: a.py", result["bundle"])
        self.assertIn("path: b.py", result["bundle"])
        self.assertEqual(result["bundle"].count(CLOSE_MARKER), 1)
        self.assertEqual(len(calls), 3)  # plano + um por arquivo

    def test_failed_file_is_reported_not_fatal(self):
        async def chat(messages):
            last = messages[-1]["content"]
            if last == fb._PLAN_PROMPT:
                return {"text": "[[GAMA_PLAN]]\na.py\nb.py\n[[/GAMA_PLAN]]", "finish_reason": "stop"}
            if "`b.py`" in last:
                return {"text": "resposta truncada sem o caminho", "finish_reason": "stop"}
            return {"text": f"[[GAMA_FILES]]\npath: a.py\n````\nok\n````\n{CLOSE_MARKER}", "finish_reason": "stop"}

        result = run(generate_files_per_file(chat, [{"role": "user", "content": "pedido"}]))
        self.assertEqual(result["failed"], ["b.py"])
        self.assertIn("path: a.py", result["bundle"])
        self.assertNotIn("path: b.py", result["bundle"])

    def test_empty_plan_returns_empty_bundle(self):
        async def chat(messages):
            return {"text": "sem plano", "finish_reason": "stop"}

        result = run(generate_files_per_file(chat, [{"role": "user", "content": "pedido"}]))
        self.assertEqual(result["bundle"], "")
        self.assertEqual(result["paths"], [])


if __name__ == "__main__":
    unittest.main()
