"""Testes de integração HTTP com o FastAPI REAL (TestClient).

Rodam só onde fastapi, httpx e python-multipart estão instalados (ex.: Railway,
ambiente de desenvolvimento). Sem eles, a suíte é pulada, sem falhar.

Cobrem o fluxo completo pela API: identidade, isolamento entre usuários,
upload, edição, download e a materialização de projeto GitHub.
"""

import asyncio
import importlib.util
import io
import os
import shutil
import tempfile
import unittest
import zipfile
from unittest.mock import patch

from tests import _httpx_stub  # noqa: F401

def _installed(mod: str) -> bool:
    # O stub de httpx (tests/_httpx_stub) não tem __spec__; conta como ausente.
    try:
        return importlib.util.find_spec(mod) is not None
    except (ValueError, ImportError):
        return False


HAS_STACK = all(_installed(m) for m in ("fastapi", "httpx", "multipart"))
SHA = "d" * 40


@unittest.skipUnless(HAS_STACK, "fastapi/httpx/python-multipart não instalados")
class HttpIntegrationTests(unittest.TestCase):
    def setUp(self):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        from app.core import identity
        from app.routes.artifacts import router

        self.tmp = tempfile.mkdtemp()
        self._env = {k: os.environ.get(k) for k in ("DATA_DIR", "GAMA_REQUIRE_AUTH")}
        os.environ["DATA_DIR"] = os.path.join(self.tmp, "data")
        os.environ.pop("GAMA_REQUIRE_AUTH", None)

        self.identity = identity
        self._old_verifier = identity._verifier
        tokens = {"tok-A": "google_A", "tok-B": "google_B"}

        async def fake_verifier(token):
            if token not in tokens:
                raise PermissionError("token inválido")
            return tokens[token]

        identity._verifier = fake_verifier
        app = FastAPI()
        app.include_router(router)
        self.client = TestClient(app)

    def tearDown(self):
        self.identity._verifier = self._old_verifier
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    @staticmethod
    def _auth(token):
        return {"Authorization": f"Bearer {token}"}

    def _download_names(self, download_path, token):
        r = self.client.get(download_path, headers=self._auth(token))
        self.assertEqual(r.status_code, 200, r.text)
        return zipfile.ZipFile(io.BytesIO(r.content))

    def test_from_files_then_download_by_owner(self):
        r = self.client.post(
            "/artifacts/zip/from-files",
            json={"files": {"src/a.py": "print(1)\n"}, "filename": "x.zip"},
            headers=self._auth("tok-A"),
        )
        self.assertEqual(r.status_code, 200, r.text)
        zf = self._download_names(r.json()["download_path"], "tok-A")
        self.assertEqual(zf.namelist(), ["src/a.py"])

    def test_other_user_cannot_download(self):
        r = self.client.post(
            "/artifacts/zip/from-files", json={"files": {"a.py": "x"}}, headers=self._auth("tok-A")
        )
        path = r.json()["download_path"]
        self.assertEqual(self.client.get(path, headers=self._auth("tok-B")).status_code, 404)
        self.assertEqual(self.client.get(path).status_code, 404)

    def test_invalid_token_is_401_and_never_falls_back_to_header(self):
        r = self.client.post(
            "/artifacts/zip/from-files",
            json={"files": {"a.py": "x"}},
            headers={**self._auth("forjado"), "X-User-Id": "google_A"},
        )
        self.assertEqual(r.status_code, 401)

    def test_auth_required_blocks_header_only_requests(self):
        os.environ["GAMA_REQUIRE_AUTH"] = "1"
        r = self.client.post(
            "/artifacts/zip/from-files", json={"files": {"a.py": "x"}}, headers={"X-User-Id": "google_A"}
        )
        self.assertEqual(r.status_code, 401)

    def test_legacy_header_mode_and_validation(self):
        ok = self.client.post(
            "/artifacts/zip/from-files", json={"files": {"a.py": "x"}}, headers={"X-User-Id": "user_1"}
        )
        self.assertEqual(ok.status_code, 200, ok.text)
        bad = self.client.post(
            "/artifacts/zip/from-files", json={"files": {"a.py": "x"}}, headers={"X-User-Id": "a b c"}
        )
        self.assertEqual(bad.status_code, 400)

    def test_edit_upload_roundtrip(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr("repo-main/a.txt", "old")
        r = self.client.post(
            "/artifacts/zip/edit-upload",
            files={"file": ("p.zip", buf.getvalue(), "application/zip")},
            headers=self._auth("tok-A"),
        )
        self.assertEqual(r.status_code, 200, r.text)
        zf = self._download_names(r.json()["download_path"], "tok-A")
        self.assertIn("a.txt", zf.namelist())

    def test_upload_over_limit_returns_413(self):
        from fastapi import HTTPException

        from app.routes._upload import read_upload_limited

        class Fake:
            def __init__(self, data):
                self._b = io.BytesIO(data)

            async def read(self, n):
                return self._b.read(n)

        with self.assertRaises(HTTPException) as ctx:
            asyncio.run(read_upload_limited(Fake(b"x" * 100), limit=10))
        self.assertEqual(ctx.exception.status_code, 413)

    def test_zip_from_github_project_materializes_then_zips(self):
        from app.core.code_analyzer import index_store
        from app.core.document_builder import github_materializer

        pid = index_store.new_project_id()
        index_store.save_meta(pid, {
            "name": "o/r", "user_id": "google_A", "github_lazy": True, "scan_root": ".",
            "source": {"type": "github", "owner": "o", "repo": "r", "branch": "main", "commit_sha": SHA},
            "map": {"files": [{"path": "src/main.py", "size": 5}]},
        })
        index_store.workspace(pid).mkdir(parents=True, exist_ok=True)

        async def fake(owner, repo, path, *, ref, max_bytes):
            self.assertEqual(ref, SHA)
            return b"print(1)\n"

        with patch.object(github_materializer, "fetch_raw_bytes", side_effect=fake):
            r = self.client.post("/artifacts/zip/from-project", json={"project_id": pid}, headers=self._auth("tok-A"))
        self.assertEqual(r.status_code, 200, r.text)
        zf = self._download_names(r.json()["download_path"], "tok-A")
        self.assertEqual(zf.namelist(), ["src/main.py"])


if __name__ == "__main__":
    unittest.main()
