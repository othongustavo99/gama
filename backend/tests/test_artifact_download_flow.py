"""Testes de ponta a ponta para criação, isolamento e download de artefatos ZIP."""
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
from app.routes.artifacts import router as artifacts_router


class ArtifactDownloadFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gama-artifact-download-")
        self.old_data = os.environ.get("DATA_DIR")
        self.old_auth = os.environ.get("GAMA_REQUIRE_AUTH")
        os.environ["DATA_DIR"] = str(Path(self.tmp) / "data")
        os.environ["GAMA_REQUIRE_AUTH"] = "1"
        self.old_verifier = identity._verifier
        identity._token_cache.clear()
        tokens = {"owner-token": "google_owner", "other-token": "google_other"}

        async def fake_verifier(token: str) -> str:
            if token not in tokens:
                raise PermissionError("token inválido")
            return tokens[token]

        identity._verifier = fake_verifier
        app = FastAPI()
        app.include_router(artifacts_router)
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
    def auth(token: str, user_id: str | None = None) -> dict[str, str]:
        headers = {"Authorization": f"Bearer {token}"}
        if user_id:
            headers["X-User-Id"] = user_id
        return headers

    def test_create_downloaded_zip_is_valid_and_contains_complete_files(self):
        created = self.client.post(
            "/artifacts/zip/from-files",
            json={"filename": "fixes.zip", "files": {
                "lib/main.dart": "void main() { print('Gamma'); }\n",
                "README.md": "Arquivos completos\n",
            }},
            headers=self.auth("owner-token"),
        )
        self.assertEqual(created.status_code, 200, created.text)
        path = created.json()["download_path"]
        downloaded = self.client.get(path, headers=self.auth("owner-token"))
        self.assertEqual(downloaded.status_code, 200, downloaded.text)
        self.assertEqual(downloaded.headers.get("cache-control"), "private, no-store")
        with zipfile.ZipFile(io.BytesIO(downloaded.content)) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()), {"lib/main.dart", "README.md"})
            self.assertEqual(archive.read("lib/main.dart").decode(), "void main() { print('Gamma'); }\n")

    def test_another_user_cannot_read_metadata_or_download_even_with_forged_header(self):
        created = self.client.post(
            "/artifacts/zip/from-files",
            json={"files": {"private.py": "print('private')\n"}},
            headers=self.auth("owner-token"),
        )
        self.assertEqual(created.status_code, 200, created.text)
        path = created.json()["download_path"]
        other_headers = self.auth("other-token", "google_owner")
        self.assertEqual(self.client.get(path, headers=other_headers).status_code, 404)
        self.assertEqual(self.client.get(path.rsplit("/download", 1)[0], headers=other_headers).status_code, 404)

    def test_missing_or_invalid_bearer_does_not_fall_back_to_user_header(self):
        created = self.client.post(
            "/artifacts/zip/from-files", json={"files": {"a.py": "print(1)"}},
            headers=self.auth("owner-token"),
        )
        path = created.json()["download_path"]
        response = self.client.get(path, headers={"X-User-Id": "google_owner", "Authorization": "Bearer invalid-token"})
        self.assertEqual(response.status_code, 401)


if __name__ == "__main__":
    unittest.main()
