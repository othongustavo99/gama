"""Regressões de autenticação e isolamento de memória/conversas/projetos."""
from __future__ import annotations

import io
import os
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core import identity
from app.core.code_analyzer.pipeline import ingest_zip
from app.routes.conversations import router as conversations_router
from app.routes.memory import router as memory_router
from app.routes.project import router as project_router


class UserIsolationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gama-user-isolation-")
        self.old_data = os.environ.get("DATA_DIR")
        self.old_auth = os.environ.get("GAMA_REQUIRE_AUTH")
        os.environ["DATA_DIR"] = str(Path(self.tmp) / "data")
        os.environ["GAMA_REQUIRE_AUTH"] = "1"
        self.old_verifier = identity._verifier
        identity._token_cache.clear()
        tokens = {
            "alpha-token": "google_email_alpha@example.com",
            "beta-token": "google_email_beta@example.com",
        }

        async def fake_verifier(token: str) -> str:
            if token not in tokens:
                raise PermissionError("token inválido")
            return tokens[token]

        identity._verifier = fake_verifier
        app = FastAPI()
        app.include_router(memory_router)
        app.include_router(conversations_router)
        app.include_router(project_router)
        self.client = TestClient(app)

    def tearDown(self):
        identity._verifier = self.old_verifier
        identity._token_cache.clear()
        if self.old_data is None:
            os.environ.pop("DATA_DIR", None)
        else:
            os.environ["DATA_DIR"] = self.old_data
        if self.old_auth is None:
            os.environ.pop("GAMA_REQUIRE_AUTH", None)
        else:
            os.environ["GAMA_REQUIRE_AUTH"] = self.old_auth
        shutil.rmtree(self.tmp, ignore_errors=True)

    @staticmethod
    def headers(token: str, forged_user_id: str | None = None) -> dict[str, str]:
        result = {"Authorization": f"Bearer {token}"}
        if forged_user_id:
            result["X-User-Id"] = forged_user_id
        return result

    def test_memory_isolated_even_when_client_forges_x_user_id(self):
        saved = self.client.post(
            "/memory", json={"text": "Informação privada da conta alpha"},
            headers=self.headers("alpha-token"),
        )
        self.assertEqual(saved.status_code, 200, saved.text)
        alpha = self.client.get("/memory", headers=self.headers("alpha-token"))
        beta = self.client.get(
            "/memory", headers=self.headers("beta-token", "google_email_alpha@example.com")
        )
        self.assertEqual(alpha.status_code, 200)
        self.assertEqual(len(alpha.json()["facts"]), 1)
        self.assertEqual(beta.status_code, 200)
        self.assertEqual(beta.json()["facts"], [])

    def test_header_only_request_is_rejected_when_auth_required(self):
        response = self.client.get("/memory", headers={"X-User-Id": "google_email_alpha@example.com"})
        self.assertEqual(response.status_code, 401)

    def test_conversations_isolated_between_accounts(self):
        saved = self.client.put(
            "/conversations/private-conv",
            json={"id": "private-conv", "title": "Só alpha", "messages": []},
            headers=self.headers("alpha-token"),
        )
        self.assertEqual(saved.status_code, 200, saved.text)
        alpha = self.client.get("/conversations", headers=self.headers("alpha-token"))
        beta = self.client.get("/conversations", headers=self.headers("beta-token"))
        self.assertEqual(alpha.json()["count"], 1)
        self.assertEqual(beta.json()["count"], 0)

    def test_project_context_and_summary_require_owner(self):
        content = io.BytesIO()
        with zipfile.ZipFile(content, "w") as archive:
            archive.writestr("sample.py", "def hello():\n    return 'private'\n")
        summary = ingest_zip(content.getvalue(), name="private.zip", user_id="google_email_alpha@example.com")
        pid = summary["project_id"]
        own = self.client.get(f"/project/{pid}", headers=self.headers("alpha-token"))
        other = self.client.get(f"/project/{pid}", headers=self.headers("beta-token"))
        context = self.client.post(
            f"/project/{pid}/context", json={"query": "hello function"},
            headers=self.headers("beta-token"),
        )
        self.assertEqual(own.status_code, 200, own.text)
        self.assertEqual(other.status_code, 404)
        self.assertEqual(context.status_code, 404)


if __name__ == "__main__":
    unittest.main()
