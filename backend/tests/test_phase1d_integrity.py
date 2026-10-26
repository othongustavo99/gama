"""Fase 1D: integridade real do armazenamento e entrega de arquivos."""
from __future__ import annotations

import hashlib
import io
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core import identity
from app.core.document_builder import store
from app.core.document_builder.zip_builder import build_zip_with_report
from app.routes.artifacts import router


class ArtifactIntegrityRegressionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gamma-1d-")
        self.env = patch.dict(os.environ, {"DATA_DIR": self.tmp.name, "GAMA_REQUIRE_AUTH": "1"})
        self.env.start()
        self.old_verifier = identity._verifier
        identity._token_cache.clear()

        async def fake_verifier(token):
            if token == "ok":
                return "google_owner"
            raise PermissionError("Token inválido")

        identity._verifier = fake_verifier
        app = FastAPI()
        app.include_router(router)
        self.client = TestClient(app)
        self.auth = {"Authorization": "Bearer ok"}

    def tearDown(self):
        identity._verifier = self.old_verifier
        identity._token_cache.clear()
        self.env.stop()
        self.tmp.cleanup()

    def test_metadata_cannot_replace_owner_path_size_or_digest(self):
        payload = b"arquivo verificado"
        item = store.save_artifact(
            kind="zip", filename="meu.zip", data=payload,
            user_id="google_owner",
            meta={
                "user_id": "google_other", "size": 1, "sha256": "f" * 64,
                "path": "/tmp/elsewhere", "filename": "evil.exe",
                "included_files": 1,
            },
        )
        self.assertEqual(item["user_id"], "google_owner")
        self.assertEqual(item["size"], len(payload))
        self.assertEqual(item["sha256"], hashlib.sha256(payload).hexdigest())
        self.assertEqual(item["filename"], "meu.zip")
        self.assertEqual(item["included_files"], 1)
        self.assertIsNone(store.load_artifact(item["artifact_id"], user_id="google_other"))

    def test_downloads_are_hashed_and_corruption_is_rejected(self):
        response = self.client.post(
            "/artifacts/zip/from-files",
            json={"filename": "app.zip", "files": {"main.dart": "void main() {}"}},
            headers=self.auth,
        )
        self.assertEqual(response.status_code, 200, response.text)
        item = response.json()
        downloaded = self.client.get(item["download_path"], headers=self.auth)
        self.assertEqual(downloaded.status_code, 200)
        self.assertEqual(downloaded.headers["x-gama-sha256"], hashlib.sha256(downloaded.content).hexdigest())
        self.assertEqual(int(downloaded.headers["x-gama-file-size"]), len(downloaded.content))
        self.assertEqual(self.client.get("/artifacts/" + item["artifact_id"], headers=self.auth).json()["sha256"], item["sha256"])
        with zipfile.ZipFile(io.BytesIO(downloaded.content)) as zf:
            self.assertEqual(zf.read("main.dart"), b"void main() {}")

        stored = store.load_artifact(item["artifact_id"], user_id="google_owner")
        file = Path(stored["path"])
        old = file.read_bytes()
        file.write_bytes(old[:-1] + bytes([old[-1] ^ 1]))
        corrupt = self.client.get(item["download_path"], headers=self.auth)
        self.assertEqual(corrupt.status_code, 409)

    def test_truncated_on_skipped_oversized_files(self):
        root = Path(self.tmp.name) / "src"
        root.mkdir()
        (root / "short.dart").write_text("ok", encoding="utf8")
        (root / "big.dart").write_text("a" * 20, encoding="utf8")
        data, report = build_zip_with_report(root, max_file_size=10)
        self.assertTrue(report["truncated"])
        self.assertEqual(report["included"], 1)
        self.assertTrue(any(item["path"] == "big.dart" for item in report["skipped"]))
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            self.assertEqual(zf.namelist(), ["short.dart"])


if __name__ == "__main__":
    unittest.main()

class UploadAndGenerationRegressionTests(unittest.IsolatedAsyncioTestCase):
    async def test_upload_preflight_rejects_oversized_file(self):
        from fastapi import HTTPException, UploadFile
        from app.routes._upload import read_upload_limited
        import io
        file = UploadFile(filename="oversized.zip", file=io.BytesIO(b"hello"), size=500)
        with self.assertRaises(HTTPException) as cm:
            await read_upload_limited(file, limit=20)
        self.assertEqual(cm.exception.status_code, 413)

    async def test_duplicate_active_generation_is_rejected_before_spending_tokens(self):
        from fastapi import HTTPException
        from app.models import ChatMessage, ChatRequest
        from app.routes import chat as chat_function
        import importlib
        mod = importlib.import_module("app.routes.chat")
        loop = __import__("asyncio").get_running_loop()
        unfinished = loop.create_future()
        key = ("google_owner", "assistant-123")
        # O endpoint só consulta .done() do trabalho que já está em andamento.
        with patch.dict(mod._background_generation_tasks, {key: (unfinished, None)}):
            request = ChatRequest(model="dummy", assistant_message_id=key[1],
                                  messages=[ChatMessage(role="user", content="Olá")])
            with self.assertRaises(HTTPException) as cm:
                await mod.chat(request, user_id=key[0])
            self.assertEqual(cm.exception.status_code, 409)
        unfinished.cancel()
