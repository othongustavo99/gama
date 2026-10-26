"""Testes do preflight comercial (sem internet ou credenciais reais)."""

import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app.core.production_guard import (  # noqa: E402
    assert_safe_production_configuration,
    production_configuration_errors,
)


class ProductionGuardTest(unittest.TestCase):
    def setUp(self):
        self.good = {
            "GAMA_PRODUCTION_MODE": "1",
            "GAMA_REQUIRE_AUTH": "1",
            "GOOGLE_OAUTH_CLIENT_IDS": "web.apps.googleusercontent.com",
            "LLM_PROVIDER": "openrouter",
            "OPENROUTER_API_KEY": "test-only-not-real",
        }

    def test_development_has_no_preflight(self):
        self.assertEqual(production_configuration_errors({"GAMA_REQUIRE_AUTH": "0"}), [])

    def test_production_accepts_google_only_without_embedded_app_secret(self):
        self.assertEqual(production_configuration_errors(self.good), [])

    def test_production_rejects_legacy_identity(self):
        params = dict(self.good, GAMA_REQUIRE_AUTH="0")
        self.assertTrue(any("GAMA_REQUIRE_AUTH" in x for x in production_configuration_errors(params)))

    def test_production_requires_oauth_audience(self):
        params = dict(self.good, GOOGLE_OAUTH_CLIENT_IDS="")
        self.assertTrue(any("GOOGLE_OAUTH_CLIENT_IDS" in x for x in production_configuration_errors(params)))

    def test_production_rejects_placeholder_client_id(self):
        params = dict(self.good, GOOGLE_OAUTH_CLIENT_IDS="SEU_WEB_CLIENT_ID")
        self.assertNotEqual(production_configuration_errors(params), [])

    def test_if_api_key_required_it_must_exist(self):
        params = dict(self.good, GAMA_REQUIRE_API_KEY="1")
        self.assertTrue(any("GAMA_API_KEY" in x for x in production_configuration_errors(params)))

    def test_production_requires_provider_credential(self):
        params = dict(self.good, OPENROUTER_API_KEY="")
        self.assertTrue(any("OPENROUTER_API_KEY" in x for x in production_configuration_errors(params)))

    def test_safe_production_guard_raises_on_bad_config(self):
        with patch.dict(os.environ, dict(self.good, GAMA_REQUIRE_AUTH="0"), clear=True):
            with self.assertRaisesRegex(RuntimeError, "GAMA_REQUIRE_AUTH"):
                assert_safe_production_configuration()

    def test_public_api_tools_require_identity(self):
        # Em processo isolado: outros testes inserem stubs de app.web_search,
        # incompatíveis com o import da aplicação principal FastAPI.
        import subprocess
        code = """from fastapi.testclient import TestClient
from app.main import app
from unittest.mock import patch
import os
with patch.dict(os.environ, {'GAMA_REQUIRE_AUTH': '1'}):
    client = TestClient(app)
    assert client.get('/models').status_code == 401
    assert client.get('/search', params={'q': 'gamma'}).status_code == 401
    assert client.post('/tts', json={'text': 'oi'}).status_code == 401
    assert client.post('/extract', files={'file': ('x.txt', b'hello')}).status_code == 401
"""
        result = subprocess.run(
            [sys.executable, "-c", code],
            cwd=os.path.join(os.path.dirname(__file__), ".."),
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_safe_production_guard_allows_good_config(self):
        with patch.dict(os.environ, self.good, clear=True):
            assert_safe_production_configuration()


if __name__ == "__main__":
    unittest.main()
