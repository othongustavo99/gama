from __future__ import annotations

import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
os.environ.setdefault("DATA_DIR", tempfile.mkdtemp())

import _httpx_stub  # noqa: F401,E402

from app.core.code_analyzer import github_reader  # noqa: E402
from app.core.code_analyzer.source_detector import parse_github_url  # noqa: E402


class FakeResponse:
    def __init__(self, status_code=200, payload=None, content=b""):
        self.status_code = status_code
        self._payload = payload or {}
        self.content = content
        self.headers = {}
        self.request = None

    def json(self):
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    async def aiter_bytes(self):
        if self.content:
            yield self.content


class FakeStream:
    def __init__(self, response):
        self.response = response

    async def __aenter__(self):
        return self.response

    async def __aexit__(self, *args):
        return False


class FakeAsyncClient:
    handler = None
    requested_urls: list[str] = []

    def __init__(self, *args, **kwargs):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def get(self, url, params=None):
        self.requested_urls.append(str(url))
        return type(self).handler(str(url), params or {})

    def stream(self, method, url):
        self.requested_urls.append(str(url))
        return FakeStream(type(self).handler(str(url), {}))


def run_immediate(coroutine):
    """Run fake-I/O coroutines without opening a Windows loopback socket."""
    try:
        coroutine.send(None)
    except StopIteration as completed:
        return completed.value
    raise AssertionError("Fake GitHub I/O unexpectedly yielded control")


class GitHubCodeAnalyzerTests(unittest.TestCase):
    def setUp(self):
        FakeAsyncClient.requested_urls = []

    def _get_tree(self, handler, branch="main"):
        FakeAsyncClient.handler = handler
        with patch.object(github_reader.httpx, "AsyncClient", FakeAsyncClient):
            return run_immediate(github_reader.get_tree("owner", "repo", branch))

    def test_parse_blob_and_tree_links_with_encoded_branch_slash(self):
        blob = parse_github_url(
            "Leia https://github.com/acme/demo/blob/feature%2Flogin/src/auth.py agora"
        )
        self.assertEqual(blob["object_type"], "blob")
        self.assertEqual(blob["branch"], "feature/login")
        self.assertEqual(blob["path"], "src/auth.py")

        tree = parse_github_url("https://github.com/acme/demo/tree/main/backend/app")
        self.assertEqual(tree["object_type"], "tree")
        self.assertEqual(tree["path"], "backend/app")

    def test_branch_with_slash_is_encoded_for_github_ref_api(self):
        def handler(url, _params):
            if "/git/ref/heads/feature%2Flogin" in url:
                return FakeResponse(payload={"object": {"sha": "commit1", "type": "commit"}})
            if "/git/commits/commit1" in url:
                return FakeResponse(payload={"tree": {"sha": "tree1"}})
            if "/git/trees/tree1" in url:
                return FakeResponse(payload={"tree": [{"path": "main.py", "type": "blob"}]})
            return FakeResponse(404)

        tree_sha, entries, resolved_ref, partial = self._get_tree(handler, "feature/login")
        self.assertEqual(tree_sha, "tree1")
        self.assertEqual(entries[0]["path"], "main.py")
        self.assertEqual(resolved_ref, "feature/login")
        self.assertFalse(partial)
        self.assertTrue(any("feature%2Flogin" in url for url in FakeAsyncClient.requested_urls))

    def test_annotated_tag_is_peeled_to_commit(self):
        def handler(url, _params):
            if "/git/ref/heads/v1.2.0" in url:
                return FakeResponse(404)
            if "/git/ref/tags/v1.2.0" in url:
                return FakeResponse(payload={"object": {"sha": "tag1", "type": "tag"}})
            if "/git/tags/tag1" in url:
                return FakeResponse(payload={"object": {"sha": "commit1", "type": "commit"}})
            if "/git/commits/commit1" in url:
                return FakeResponse(payload={"tree": {"sha": "tree1"}})
            if "/git/trees/tree1" in url:
                return FakeResponse(payload={"tree": []})
            return FakeResponse(404)

        _, _, resolved_ref, _ = self._get_tree(handler, "v1.2.0")
        self.assertEqual(resolved_ref, "v1.2.0")
        self.assertTrue(any("/git/tags/tag1" in url for url in FakeAsyncClient.requested_urls))
        self.assertTrue(any("/git/commits/commit1" in url for url in FakeAsyncClient.requested_urls))

    def test_truncated_recursive_tree_walks_child_trees_and_marks_partial(self):
        def handler(url, params):
            if "/git/ref/heads/main" in url:
                return FakeResponse(payload={"object": {"sha": "commit1", "type": "commit"}})
            if "/git/commits/commit1" in url:
                return FakeResponse(payload={"tree": {"sha": "root-tree"}})
            if "/git/trees/root-tree" in url and params.get("recursive") == "1":
                return FakeResponse(payload={"truncated": True, "tree": []})
            if "/git/trees/root-tree" in url:
                return FakeResponse(payload={"tree": [
                    {"path": "README.md", "type": "blob", "sha": "b1"},
                    {"path": "src", "type": "tree", "sha": "src-tree"},
                ]})
            if "/git/trees/src-tree" in url:
                return FakeResponse(payload={"tree": [
                    {"path": "main.py", "type": "blob", "sha": "b2"},
                ]})
            return FakeResponse(404)

        tree_sha, entries, _, partial = self._get_tree(handler)
        self.assertEqual(tree_sha, "root-tree")
        self.assertEqual({item["path"] for item in entries}, {"README.md", "src/main.py"})
        self.assertTrue(partial)

    def test_default_branch_falls_back_to_master(self):
        def handler(url, _params):
            if url.endswith("/git/ref/heads/main"):
                return FakeResponse(404)
            if url.endswith("/repos/owner/repo"):
                return FakeResponse(payload={"default_branch": "master"})
            if url.endswith("/git/ref/heads/master"):
                return FakeResponse(payload={"object": {"sha": "commit1", "type": "commit"}})
            if url.endswith("/git/commits/commit1"):
                return FakeResponse(payload={"tree": {"sha": "tree1"}})
            if "/git/trees/tree1" in url:
                return FakeResponse(payload={"tree": []})
            return FakeResponse(404)

        _, _, resolved_ref, _ = self._get_tree(handler)
        self.assertEqual(resolved_ref, "master")

    def test_raw_and_api_download_failure_returns_empty_content(self):
        FakeAsyncClient.handler = lambda _url, _params: FakeResponse(403)
        with patch.object(github_reader.httpx, "AsyncClient", FakeAsyncClient):
            result = run_immediate(github_reader.fetch_raw_content("owner", "repo", "src/a.py"))
        self.assertEqual(result, "")
        self.assertGreaterEqual(len(FakeAsyncClient.requested_urls), 5)


if __name__ == "__main__":
    unittest.main()
