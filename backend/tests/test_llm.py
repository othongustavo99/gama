import asyncio
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
os.environ["DATA_DIR"] = tempfile.mkdtemp()
os.environ["OPENROUTER_API_KEY"] = "test-key"
os.environ["LLM_RETRIES"] = "2"
import _httpx_stub  # noqa: F401,E402
import httpx  # noqa: E402

from app import llm as llm_mod  # noqa: E402
from app.llm import LLMError, iter_openai_events, parse_sse_line  # noqa: E402


async def aiter(lines):
    for line in lines:
        yield line


def sse(obj):
    return "data: " + json.dumps(obj)


async def collect(lines):
    return [ev async for ev in iter_openai_events(aiter(lines))]


class SSETest(unittest.TestCase):
    def test_parse_line(self):
        self.assertIsNone(parse_sse_line(""))
        self.assertIsNone(parse_sse_line(": OPENROUTER PROCESSING"))
        self.assertEqual(parse_sse_line("data: [DONE]"), "DONE")
        self.assertEqual(parse_sse_line('data: {"a": 1}'), {"a": 1})
        self.assertIsNone(parse_sse_line("data: {quebrado"))

    def test_tokens_and_single_finish(self):
        evs = asyncio.run(collect([
            ": keepalive",
            sse({"choices": [{"delta": {"content": "Olá"}}]}),
            sse({"choices": [{"delta": {"content": " mundo"}, "finish_reason": "stop"}]}),
            sse({"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}}),
            "data: [DONE]",
        ]))
        self.assertEqual("".join(e["text"] for e in evs if e["type"] == "token"), "Olá mundo")
        self.assertEqual([e["type"] for e in evs].count("finish"), 1)
        self.assertTrue(any(e["type"] == "usage" for e in evs))

    def test_tool_calls_assembled_across_chunks(self):
        evs = asyncio.run(collect([
            sse({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "function": {"name": "web_search", "arguments": ""}}]}}]}),
            sse({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": '{"query": "flut'}}]}}]}),
            sse({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": 'ter 4"}'}}]}}]}),
            sse({"choices": [{"delta": {"tool_calls": [{"index": 1, "id": "c2", "function": {"name": "get_datetime", "arguments": "{}"}}]}}]}),
            sse({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}),
            "data: [DONE]",
        ]))
        calls = [e for e in evs if e["type"] == "tool_calls"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["calls"][0], {"id": "c1", "name": "web_search", "arguments": '{"query": "flutter 4"}'})
        self.assertEqual(calls[0]["calls"][1]["name"], "get_datetime")

    def test_tool_calls_flushed_without_finish_reason(self):
        evs = asyncio.run(collect([
            sse({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "x", "function": {"name": "calculator", "arguments": "{}"}}]}}]}),
            "data: [DONE]",
        ]))
        self.assertTrue(any(e["type"] == "tool_calls" for e in evs))

    def test_stream_error_chunk(self):
        with self.assertRaises(LLMError):
            asyncio.run(collect([sse({"error": {"message": "boom"}})]))


class ErrorMappingTest(unittest.TestCase):
    def test_public_messages_do_not_leak_body(self):
        e = LLMError.from_response(401, '{"error":"Invalid key sk-or-v1-SECRET"}')
        self.assertNotIn("SECRET", e.public_message)
        self.assertEqual(LLMError.from_response(402, "").status, 402)
        self.assertIn("grande demais", LLMError.from_response(400, "maximum context length exceeded").public_message)

    def test_tools_unsupported_detection(self):
        self.assertTrue(LLMError.from_response(404, "No endpoints found that support tool use").tools_unsupported)
        self.assertFalse(LLMError.from_response(429, "tool").tools_unsupported)


class FakeResp:
    def __init__(self, status, payload=None, text="", headers=None):
        self.status_code, self._p, self.text, self.headers = status, payload, text, headers or {}

    @property
    def is_success(self):
        return self.status_code < 400

    def json(self):
        return self._p


class FakeClient:
    is_closed = False

    def __init__(self, script):
        self.script, self.calls, self.last_json = list(script), 0, None

    async def post(self, url, headers=None, json=None, timeout=None):
        self.calls += 1
        self.last_json = json
        item = self.script.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


class ChatOnceTest(unittest.TestCase):
    def setUp(self):
        self.client = llm_mod.LLMClient()
        llm_mod.asyncio_sleep = None

        async def no_sleep(_):
            return None
        self._orig_sleep = llm_mod.asyncio.sleep
        llm_mod.asyncio.sleep = no_sleep

    def tearDown(self):
        llm_mod.asyncio.sleep = self._orig_sleep

    def ok(self, text="oi"):
        return FakeResp(200, {"choices": [{"message": {"content": text}}]})

    def test_retries_then_succeeds_and_applies_max_tokens(self):
        self.client._client = FakeClient([FakeResp(429, text="slow down"), FakeResp(503, text="x"), self.ok("feito")])
        out = asyncio.run(self.client.chat_once("openai/gpt-5.4-mini", [{"role": "user", "content": "oi"}]))
        self.assertEqual(out, "feito")
        self.assertEqual(self.client._client.calls, 3)
        self.assertEqual(self.client._client.last_json["max_tokens"], 4096)

    def test_does_not_retry_auth_errors(self):
        self.client._client = FakeClient([FakeResp(401, text="bad key")])
        with self.assertRaises(LLMError) as cm:
            asyncio.run(self.client.chat_once("m", [{"role": "user", "content": "oi"}]))
        self.assertEqual(self.client._client.calls, 1)
        self.assertEqual(cm.exception.status, 401)

    def test_gives_up_after_retries(self):
        attempts = llm_mod.settings.LLM_RETRIES + 1
        self.client._client = FakeClient([httpx.ConnectError("x")] * attempts)
        with self.assertRaises(LLMError):
            asyncio.run(self.client.chat_once("m", [{"role": "user", "content": "oi"}]))
        self.assertEqual(self.client._client.calls, attempts)


if __name__ == "__main__":
    unittest.main()
