"""Testes v3 que rodam só com a stdlib: cache por commit, dedupe, limite de
concorrência, evicção, SHA do commit, isolamento no store e lista de exclusão."""

import asyncio
import io
import os
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from tests import _httpx_stub  # noqa: F401

from app.core.code_analyzer import github_reader, index_store
from app.core.code_analyzer import github_cache
from app.core.document_builder import github_materializer, pipeline, store
from app.core.document_builder.zip_builder import build_zip_with_report

SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40


class _Env(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self._env = {k: os.environ.get(k) for k in ("DATA_DIR", "GITHUB_CACHE_MAX_MB", "GITHUB_MATERIALIZE_CONCURRENCY")}
        os.environ["DATA_DIR"] = str(self.tmp / "data")
        os.environ.pop("GITHUB_CACHE_MAX_MB", None)
        os.environ.pop("GITHUB_MATERIALIZE_CONCURRENCY", None)

    def tearDown(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _project(self, commit, files):
        pid = index_store.new_project_id()
        src = {"type": "github", "owner": "o", "repo": "r", "branch": "main"}
        if commit is not None:
            src["commit_sha"] = commit
        index_store.save_meta(pid, {
            "name": "o/r", "github_lazy": True, "source": src, "scan_root": ".",
            "map": {"files": [{"path": p, "size": 10} for p in files]},
        })
        index_store.workspace(pid).mkdir(parents=True, exist_ok=True)
        return pid


class GitHubCacheTests(_Env):
    def test_second_project_same_commit_does_not_redownload(self):
        calls = []

        async def fake(owner, repo, path, *, ref, max_bytes):
            calls.append((path, ref))
            return f"// {path}\n".encode()

        p1 = self._project(SHA_A, ["src/a.py", "src/b.py"])
        p2 = self._project(SHA_A, ["src/a.py", "src/b.py"])
        with patch.object(github_materializer, "fetch_raw_bytes", side_effect=fake):
            r1 = asyncio.run(github_materializer.materialize_github_project(p1))
            r2 = asyncio.run(github_materializer.materialize_github_project(p2))
        self.assertEqual(len(calls), 2, "o commit deve ser baixado uma única vez")
        self.assertFalse(r1["cached"])
        self.assertTrue(r2["cached"])
        self.assertEqual(r1["ref"], SHA_A, "download deve usar o SHA, não o branch")
        self.assertTrue((index_store.workspace(p2) / "src" / "b.py").is_file())

    def test_concurrent_requests_for_same_commit_share_one_download(self):
        calls = []

        async def fake(owner, repo, path, *, ref, max_bytes):
            calls.append(path)
            await asyncio.sleep(0.01)
            return b"x"

        pids = [self._project(SHA_A, ["a.py", "b.py", "c.py"]) for _ in range(4)]

        async def run_all():
            return await asyncio.gather(*(github_materializer.materialize_github_project(p) for p in pids))

        with patch.object(github_materializer, "fetch_raw_bytes", side_effect=fake):
            results = asyncio.run(run_all())
        self.assertEqual(len(calls), 3, "4 pedidos simultâneos, 1 download de 3 arquivos")
        self.assertTrue(all(r["written"] == 3 for r in results))

    def test_concurrency_limit_is_respected(self):
        os.environ["GITHUB_MATERIALIZE_CONCURRENCY"] = "1"
        active = {"now": 0, "max": 0}

        async def fake(owner, repo, path, *, ref, max_bytes):
            active["now"] += 1
            active["max"] = max(active["max"], active["now"])
            await asyncio.sleep(0.005)
            active["now"] -= 1
            return b"x"

        pids = [self._project(sha, ["one.py"]) for sha in (SHA_A, SHA_B, SHA_C)]

        async def run_all():
            return await asyncio.gather(*(github_materializer.materialize_github_project(p) for p in pids))

        with patch.object(github_materializer, "fetch_raw_bytes", side_effect=fake):
            asyncio.run(run_all())
        self.assertEqual(active["max"], 1, "com limite 1, no máximo um repositório por vez")

    def test_eviction_removes_oldest_commit_over_limit(self):
        os.environ["GITHUB_CACHE_MAX_MB"] = "1"
        blob = b"x" * (600 * 1024)

        def make_commit(sha, mtime):
            d = github_cache.cache_dir("o", "r", sha)
            d.mkdir(parents=True, exist_ok=True)
            (d / "big.bin").write_bytes(blob)
            (d / ".complete").write_text("1")
            os.utime(d / ".complete", (mtime, mtime))
            return d

        old = make_commit(SHA_A, 1_000_000_000)
        new = make_commit(SHA_B, 2_000_000_000)
        removed = github_cache.evict_if_needed(now=2_000_000_100)
        self.assertEqual(removed, 1)
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())

    def test_invalid_sha_or_repo_is_rejected(self):
        with self.assertRaises(ValueError):
            github_cache.cache_dir("o", "r", "../../etc")
        with self.assertRaises(ValueError):
            github_cache.cache_dir("o/../x", "r", SHA_A)


class CommitShaTests(unittest.TestCase):
    def test_get_tree_full_returns_commit_sha(self):
        class R:
            def __init__(self, status=200, payload=None):
                self.status_code, self._p = status, payload or {}
                self.headers = {}

            def json(self):
                return self._p

            def raise_for_status(self):
                if self.status_code >= 400:
                    raise RuntimeError(self.status_code)

        def handler(url):
            if "/git/ref/heads/main" in url:
                return R(payload={"object": {"sha": SHA_A, "type": "commit"}})
            if url.endswith(f"/git/commits/{SHA_A}"):
                return R(payload={"tree": {"sha": "tree1"}})
            if "/git/trees/tree1" in url:
                return R(payload={"tree": [{"path": "a.py", "type": "blob", "sha": "s", "size": 3}], "truncated": False})
            return R(404)

        class Client:
            def __init__(self, *a, **k):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *a):
                return False

            async def get(self, url, params=None):
                return handler(url)

        with patch.object(github_reader.httpx, "AsyncClient", Client):
            tree_sha, entries, ref, partial, commit = asyncio.run(
                github_reader.get_tree_full("o", "r", "main")
            )
            legacy = asyncio.run(github_reader.get_tree("o", "r", "main"))
        self.assertEqual(commit, SHA_A)
        self.assertEqual(tree_sha, "tree1")
        self.assertEqual(entries[0]["path"], "a.py")
        self.assertEqual(legacy[2], "main")  # get_tree continua com 4 valores


class ZipUnifiedSkipTests(_Env):
    def test_project_zip_uses_same_junk_rules_as_analysis(self):
        root = self.tmp / "proj"
        (root / "lib").mkdir(parents=True)
        (root / "lib" / "a.dart").write_text("x")
        (root / ".git").mkdir()
        (root / ".git" / "HEAD").write_text("ref")
        (root / "node_modules" / "pkg").mkdir(parents=True)
        (root / "node_modules" / "pkg" / "i.js").write_text("y")
        (root / "README.md").write_text("hi")
        data, report = build_zip_with_report(root)
        names = set(zipfile.ZipFile(io.BytesIO(data)).namelist())
        self.assertEqual(names, {"lib/a.dart", "README.md"})


class IsolationStoreTests(_Env):
    def test_artifacts_are_listed_only_for_their_owner(self):
        a = store.save_artifact(kind="zip", filename="a.zip", data=b"PK-a", user_id="google_1")
        b = store.save_artifact(kind="zip", filename="b.zip", data=b"PK-b", user_id="google_2")
        mine = [i["artifact_id"] for i in store.list_recent(user_id="google_1")]
        self.assertIn(a["artifact_id"], mine)
        self.assertNotIn(b["artifact_id"], mine)
        self.assertIsNone(store.load_artifact(b["artifact_id"], user_id="google_1"))
        self.assertIsNotNone(store.load_artifact(b["artifact_id"], user_id="google_2"))


class EndToEndServiceTests(_Env):
    def test_zip_upload_edit_download_roundtrip(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr("repo-main/lib/main.dart", "void main() {}\n")
            zf.writestr("repo-main/pubspec.yaml", "name: app\n")
        result = pipeline.apply_edits_and_zip(
            zip_bytes=buf.getvalue(),
            edits=[{"path": "lib/main.dart", "action": "replace", "old": "{}", "new": "{ print(1); }"}],
            user_id="google_1",
        )
        self.assertEqual(result["edits"]["errors"], [])
        art = store.load_artifact(result["artifact_id"], user_id="google_1", include_bytes=True)
        with zipfile.ZipFile(io.BytesIO(art["bytes"])) as zf:
            self.assertEqual(sorted(zf.namelist()), ["lib/main.dart", "pubspec.yaml"])
            self.assertEqual(zf.read("lib/main.dart").decode(), "void main() { print(1); }\n")


if __name__ == "__main__":
    unittest.main()
