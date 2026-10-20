"""Regressões para as correções de ZIP, edição de arquivos e materialização GitHub."""

import asyncio
import importlib
import importlib.util
import io
import os
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from tests import _httpx_stub  # noqa: F401  (stub quando httpx não está instalado)

from app.core.document_builder import file_editor, pipeline, store
from app.core.document_builder.validator import validate_path_safe, validate_zip
from app.core.document_builder.zip_builder import (
    build_zip_with_report,
    extract_zip_safe,
)
from app.core.code_analyzer import index_store
from app.core.document_builder import github_materializer


def _zip_bytes(entries: dict[str, bytes], symlinks: dict[str, str] | None = None) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
        for name, target in (symlinks or {}).items():
            info = zipfile.ZipInfo(name)
            info.external_attr = (0o120777 & 0xFFFF) << 16  # S_IFLNK
            zf.writestr(info, target)
    return buf.getvalue()


class _TempData(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self._old_env = os.environ.get("DATA_DIR")
        os.environ["DATA_DIR"] = str(self.tmp / "data")

    def tearDown(self):
        if self._old_env is None:
            os.environ.pop("DATA_DIR", None)
        else:
            os.environ["DATA_DIR"] = self._old_env
        shutil.rmtree(self.tmp, ignore_errors=True)


class PathValidationTests(unittest.TestCase):
    def test_rejects_unsafe_paths(self):
        for bad in ["/etc/passwd", "a/../b", "C:/x", "C:\\x", "~/x", "a\x00b", "", "   "]:
            with self.subTest(path=bad):
                self.assertFalse(validate_path_safe(bad))

    def test_accepts_normal_paths(self):
        self.assertTrue(validate_path_safe("lib/a.dart"))
        self.assertTrue(validate_path_safe("./src/x.py"))

    def test_validate_zip_flags_symlink_entries(self):
        data = _zip_bytes({"ok.txt": b"x"}, symlinks={"link": "/etc/passwd"})
        result = validate_zip(data)
        self.assertFalse(result["ok"])
        self.assertTrue(any("Link simbólico" in e for e in result["errors"]))


class ZipBuilderTests(_TempData):
    def test_symlinks_are_not_followed_and_are_reported(self):
        root = self.tmp / "proj"
        root.mkdir()
        secret = self.tmp / "secret.txt"
        secret.write_text("SEGREDO")
        (root / "main.py").write_text("print(1)")
        os.symlink(secret, root / "leak.txt")

        data, report = build_zip_with_report(root)
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            names = zf.namelist()
            self.assertIn("main.py", names)
            self.assertNotIn("leak.txt", names)
            self.assertNotIn(b"SEGREDO", b"".join(zf.read(n) for n in names))
        self.assertTrue(any(s["reason"] == "symlink" for s in report["skipped"]))

    def test_extract_rejects_symlink_and_traversal(self):
        data = _zip_bytes(
            {"ok/a.txt": b"a", "../evil.txt": b"x"},
            symlinks={"bad_link": "/etc/passwd"},
        )
        dest = self.tmp / "out"
        count = extract_zip_safe(data, dest)
        self.assertEqual(count, 1)
        self.assertTrue((dest / "ok" / "a.txt").is_file())
        self.assertFalse((dest / "bad_link").exists())
        self.assertFalse((self.tmp / "evil.txt").exists())


class FileEditorTests(_TempData):
    def test_non_utf8_file_is_not_corrupted(self):
        root = self.tmp / "ws"
        root.mkdir()
        raw = "café".encode("latin-1")  # não é UTF-8 válido
        (root / "old.txt").write_bytes(raw)
        result = file_editor.apply_edits(
            root, [{"path": "old.txt", "action": "replace", "old": "caf", "new": "x"}]
        )
        self.assertFalse(result["ok"])
        self.assertEqual((root / "old.txt").read_bytes(), raw)

    def test_replace_with_empty_old_is_refused(self):
        root = self.tmp / "ws"
        root.mkdir()
        (root / "a.txt").write_text("abc")
        result = file_editor.apply_edits(
            root, [{"path": "a.txt", "action": "replace", "old": "", "new": "X"}]
        )
        self.assertFalse(result["ok"])
        self.assertEqual((root / "a.txt").read_text(), "abc")

    def test_write_through_symlink_is_refused(self):
        root = self.tmp / "ws"
        root.mkdir()
        outside = self.tmp / "outside.txt"
        outside.write_text("intacto")
        os.symlink(outside, root / "link.txt")
        result = file_editor.apply_edits(
            root, [{"path": "link.txt", "action": "write", "content": "PWNED"}]
        )
        self.assertFalse(result["ok"])
        self.assertEqual(outside.read_text(), "intacto")


class EditAndZipRootTests(_TempData):
    def test_edits_land_inside_single_top_folder_zip(self):
        # Formato típico do "Download ZIP" do GitHub: uma pasta de topo.
        zip_in = _zip_bytes({"repo-main/lib/a.py": b"old = 1\n", "repo-main/README.md": b"hi"})
        result = pipeline.apply_edits_and_zip(
            zip_bytes=zip_in,
            edits=[{"path": "lib/a.py", "action": "replace", "old": "old = 1", "new": "new = 2"}],
            extra_files={"lib/extra.py": "x = 1\n"},
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["edits"]["errors"], [])
        art = store.load_artifact(result["artifact_id"], include_bytes=True)
        with zipfile.ZipFile(io.BytesIO(art["bytes"])) as zf:
            names = set(zf.namelist())
            self.assertIn("lib/a.py", names)
            self.assertIn("lib/extra.py", names)
            self.assertEqual(zf.read("lib/a.py"), b"new = 2\n")

    def test_root_prefix_in_edit_path_is_accepted(self):
        zip_in = _zip_bytes({"repo-main/lib/a.py": b"x = 1\n"})
        result = pipeline.apply_edits_and_zip(
            zip_bytes=zip_in,
            edits=[{"path": "repo-main/lib/a.py", "action": "write", "content": "y = 2\n"}],
        )
        art = store.load_artifact(result["artifact_id"], include_bytes=True)
        with zipfile.ZipFile(io.BytesIO(art["bytes"])) as zf:
            self.assertEqual(zf.read("lib/a.py"), b"y = 2\n")
            self.assertFalse(any(n.startswith("repo-main/") for n in zf.namelist()))


class GitHubMaterializeTests(_TempData):
    def _make_github_project(self, files):
        pid = index_store.new_project_id()
        index_store.save_meta(
            pid,
            {
                "name": "o/r",
                "github_lazy": True,
                "source": {"type": "github", "owner": "o", "repo": "r", "branch": "main"},
                "scan_root": ".",
                "map": {"files": [{"path": p, "size": 10} for p in files]},
            },
        )
        index_store.workspace(pid).mkdir(parents=True, exist_ok=True)
        return pid

    def test_zip_from_empty_github_project_is_an_error_not_an_empty_zip(self):
        pid = self._make_github_project(["src/a.py"])
        with self.assertRaises(ValueError):
            pipeline.build_zip_from_project(pid)

    def test_prepare_project_downloads_all_files_then_zip_has_them(self):
        pid = self._make_github_project(["src/a.py", "img/logo.png"])

        async def fake_bytes(owner, repo, path, *, ref, max_bytes):
            return {"src/a.py": b"print(1)\n", "img/logo.png": b"\x89PNG\x00"}.get(path)

        with patch.object(github_materializer, "fetch_raw_bytes", side_effect=fake_bytes):
            report = asyncio.run(pipeline.prepare_project(pid))
            self.assertEqual(report["written"], 2)
            info = pipeline.build_zip_from_project(pid)

        self.assertEqual(info["included_files"], 2)
        art = store.load_artifact(info["artifact_id"], include_bytes=True)
        with zipfile.ZipFile(io.BytesIO(art["bytes"])) as zf:
            self.assertEqual(sorted(zf.namelist()), ["img/logo.png", "src/a.py"])

    def test_skipped_files_are_reported(self):
        pid = self._make_github_project(["ok.py", "gone.py"])

        async def fake_bytes(owner, repo, path, *, ref, max_bytes):
            return b"x" if path == "ok.py" else None

        with patch.object(github_materializer, "fetch_raw_bytes", side_effect=fake_bytes):
            report = asyncio.run(github_materializer.materialize_github_project(pid))
        self.assertEqual(report["written"], 1)
        self.assertEqual(report["skipped"][0]["path"], "gone.py")


class GitHubRawFallbackTests(unittest.TestCase):
    def test_missing_file_does_not_spend_api_quota_without_token(self):
        from app.core.code_analyzer import github_reader

        calls = []

        class _Resp:
            status_code = 404
            headers = {}

            async def aiter_bytes(self):
                if False:
                    yield b""

        class _Stream:
            def __init__(self, url):
                calls.append(url)

            async def __aenter__(self):
                return _Resp()

            async def __aexit__(self, *a):
                return False

        class _Client:
            def __init__(self, *a, **k):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *a):
                return False

            def stream(self, method, url):
                return _Stream(url)

            async def get(self, url, **k):  # chamada à API: não deve acontecer
                calls.append(("API", url))
                raise AssertionError("API não deveria ser chamada")

        env_backup = {k: os.environ.pop(k, None) for k in ("GITHUB_TOKEN", "GH_TOKEN")}
        try:
            with patch.object(github_reader.httpx, "AsyncClient", _Client):
                result = asyncio.run(github_reader.fetch_raw_content("o", "r", "a.py"))
        finally:
            for k, v in env_backup.items():
                if v is not None:
                    os.environ[k] = v
        self.assertEqual(result, "")
        self.assertFalse(any(isinstance(c, tuple) for c in calls))


class RouteImportTests(unittest.TestCase):
    """Garante que os módulos de rota carregam (um NameError no import derruba o app inteiro)."""

    @unittest.skipUnless(importlib.util.find_spec("fastapi"), "fastapi não instalado")
    def test_route_modules_import(self):
        for mod in (
            "app.routes.artifacts",
            "app.routes.project",
            "app.routes.extract",
            "app.routes._upload",
        ):
            with self.subTest(module=mod):
                importlib.import_module(mod)


if __name__ == "__main__":
    unittest.main()
