import asyncio
import importlib.util
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("DATA_DIR", "")

from app.config import settings  # noqa: E402
from app.core.search_privacy import sanitize_search_query  # noqa: E402

# test_agent.py registra um stub de app.web_search para evitar rede. Carregamos o
# módulo real sob outro nome para que os testes desta suíte validem o arquivo real.
_web_search_path = Path(__file__).resolve().parents[1] / "app" / "web_search.py"
_web_search_spec = importlib.util.spec_from_file_location("app._web_search_privacy_test", _web_search_path)
assert _web_search_spec and _web_search_spec.loader
web_search = importlib.util.module_from_spec(_web_search_spec)
sys.modules[_web_search_spec.name] = web_search
_web_search_spec.loader.exec_module(web_search)


class SearchPrivacyTests(unittest.TestCase):
    def test_removes_code_blocks_and_masks_secrets_and_personal_data(self):
        raw = (
            "Pesquise FastAPI docs e veja este token sk-or-v1-abcdefghijklmnopqrstuvwxyz123456 "
            "e email othon.private@example.com; telefone (11) 98765-4321. "
            "```python\nOPENROUTER_API_KEY='sk-or-v1-anothersecretvalue123456'\nprint('private')\n```"
        )
        safe = sanitize_search_query(raw)
        self.assertIn("FastAPI docs", safe)
        self.assertNotIn("abcdefghijklmnopqrstuvwxyz123456", safe)
        self.assertNotIn("othon.private@example.com", safe)
        self.assertNotIn("98765-4321", safe)
        self.assertNotIn("print('private')", safe)
        self.assertNotIn("anothersecretvalue123456", safe)

    def test_redacts_bearer_jwt_and_url_query_credentials(self):
        raw = (
            "procure documentação JWT Bearer abcdefghijklmnop123456 "
            "https://example.test/docs?access_token=verysecretvalue&view=compact"
        )
        safe = sanitize_search_query(raw)
        self.assertNotIn("abcdefghijklmnop123456", safe)
        self.assertNotIn("verysecretvalue", safe)
        self.assertIn("view=compact", safe)

    def test_code_only_query_becomes_empty(self):
        self.assertEqual(sanitize_search_query("```python\nprint('segredo')\n```"), "")

    def test_off_mode_blocks_even_explicit_search_requests(self):
        old_mode = web_search.SEARCH_MODE
        old_enabled = settings.WEB_SEARCH_ENABLED
        try:
            web_search.SEARCH_MODE = "off"
            settings.WEB_SEARCH_ENABLED = True
            self.assertFalse(web_search.should_search("Pesquise na internet notícias atuais sobre Flutter"))
            self.assertEqual(asyncio.run(web_search.search_web("Pesquise na internet notícias atuais sobre Flutter")), [])
        finally:
            web_search.SEARCH_MODE = old_mode
            settings.WEB_SEARCH_ENABLED = old_enabled

    def test_explicit_mode_hides_tools_without_explicit_user_request(self):
        old_enabled = settings.WEB_SEARCH_ENABLED
        old_mode = web_search.SEARCH_MODE
        try:
            settings.WEB_SEARCH_ENABLED = True
            web_search.SEARCH_MODE = "explicit"
            self.assertFalse(web_search.web_tools_enabled_for_turn("Qual é a versão atual do Flutter?"))
            self.assertTrue(web_search.web_tools_enabled_for_turn("Pesquise na internet a versão atual do Flutter"))
        finally:
            settings.WEB_SEARCH_ENABLED = old_enabled
            web_search.SEARCH_MODE = old_mode

    def test_global_disable_blocks_direct_search_calls(self):
        old_enabled = settings.WEB_SEARCH_ENABLED
        old_mode = web_search.SEARCH_MODE
        try:
            settings.WEB_SEARCH_ENABLED = False
            web_search.SEARCH_MODE = "balanced"
            with patch.object(web_search, "_search_pipeline", new_callable=AsyncMock) as pipeline:
                result = asyncio.run(web_search.search_web("Flutter latest release and docs"))
                self.assertEqual(result, [])
                pipeline.assert_not_awaited()
        finally:
            settings.WEB_SEARCH_ENABLED = old_enabled
            web_search.SEARCH_MODE = old_mode

    def test_search_pipeline_only_receives_sanitized_query(self):
        old_enabled = settings.WEB_SEARCH_ENABLED
        old_mode = web_search.SEARCH_MODE
        try:
            settings.WEB_SEARCH_ENABLED = True
            web_search.SEARCH_MODE = "balanced"
            with patch.object(web_search, "_search_pipeline", new_callable=AsyncMock, return_value=[]) as pipeline:
                asyncio.run(web_search.search_web("Pesquise docs API_KEY=sk-or-v1-supersecretvalue123456 para FastAPI"))
                safe_query = pipeline.await_args.args[0]
                self.assertIn("FastAPI", safe_query)
                self.assertNotIn("supersecretvalue123456", safe_query)
                self.assertNotIn("API_KEY=sk-or-v1", safe_query)
        finally:
            settings.WEB_SEARCH_ENABLED = old_enabled
            web_search.SEARCH_MODE = old_mode


if __name__ == "__main__":
    unittest.main()
