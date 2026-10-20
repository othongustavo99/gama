from __future__ import annotations

import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("DATA_DIR", tempfile.mkdtemp())

from app.core.code_analyzer.deep_review import (  # noqa: E402
    append_deep_review_if_requested,
    is_deep_review_request,
    plan_review_batches,
    run_deep_review,
)
from app.core.code_analyzer.index_store import save_meta, workspace  # noqa: E402


class FakeModelClient:
    def __init__(self):
        self.calls = []

    async def chat_once(self, model, messages, *, timeout=120.0, max_tokens=None):
        self.calls.append({"model": model, "messages": messages, "max_tokens": max_tokens})
        return "Achado de teste: revisão realizada; nenhum defeito confirmado neste lote."


class DeepReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data_dir = os.environ.get("DATA_DIR")
        os.environ["DATA_DIR"] = self.temp.name
        self.project_id = "testdeepreview"
        self.root = workspace(self.project_id)
        self.root.mkdir(parents=True, exist_ok=True)
        contents = {
            "README.md": "# Projeto\nArquitetura do projeto de teste.\n",
            "app/main.py": "from app.routes.auth import login\n\ndef main():\n    return login()\n",
            "app/routes/auth.py": "def login():\n    return 'ok'\n",
            "app/services/user_service.py": "class UserService:\n    def find_user(self, user_id):\n        return user_id\n",
            "app/repositories/user_repository.py": "class UserRepository:\n    def get(self, user_id):\n        return user_id\n",
            "tests/test_auth.py": "def test_login():\n    assert True\n",
        }
        files = []
        for path, content in contents.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
            files.append({"path": path, "size": len(content), "ext": target.suffix, "lang": "Python", "important": path in {"README.md", "app/main.py"}})
        save_meta(self.project_id, {
            "name": "test-project",
            "user_id": "user-1",
            "source": {"type": "zip", "name": "test.zip"},
            "scan_root": ".",
            "map": {"file_count": len(files), "files": files, "languages": {"Python": 5}, "frameworks": ["Python"]},
            "symbols": {},
        })

    def tearDown(self):
        if self.data_dir is not None:
            os.environ["DATA_DIR"] = self.data_dir
        else:
            os.environ.pop("DATA_DIR", None)
        self.temp.cleanup()

    def test_broad_review_detection_does_not_treat_simple_fix_as_full_review(self):
        self.assertTrue(is_deep_review_request("Analise profundamente esse projeto e encontre melhorias"))
        self.assertTrue(is_deep_review_request("Faça uma revisão completa do repositório"))
        self.assertFalse(is_deep_review_request("Corrija o bug no login"))

    def test_plan_balances_paths_across_subsystems(self):
        with patch.dict(os.environ, {
            "GAMA_CODE_DEEP_BATCH_FILES": "2",
            "GAMA_CODE_DEEP_MAX_FILES": "10",
            "GAMA_CODE_DEEP_MAX_PASSES": "10",
        }):
            plan = plan_review_batches({
                "map": {"file_count": 5, "files": [
                    {"path": "README.md", "important": True},
                    {"path": "app/routes/auth.py", "important": True},
                    {"path": "app/services/user_service.py"},
                    {"path": "app/repositories/user_repository.py"},
                    {"path": "tests/test_auth.py"},
                ]}
            })
        selected = {path for batch in plan["batches"] for path in batch["paths"]}
        self.assertEqual(len(selected), 5)
        self.assertEqual(plan["omitted_paths"], [])
        self.assertGreaterEqual(len(plan["batches"]), 3)

    def test_run_deep_review_analyzes_batches_and_reports_coverage(self):
        client = FakeModelClient()
        with patch.dict(os.environ, {
            "GAMA_CODE_DEEP_BATCH_FILES": "2",
            "GAMA_CODE_DEEP_MAX_FILES": "10",
            "GAMA_CODE_DEEP_MAX_PASSES": "10",
            "GAMA_CODE_DEEP_CONCURRENCY": "2",
        }):
            result = asyncio.run(run_deep_review(
                self.project_id,
                "Analise profundamente o projeto e sugira melhorias",
                model_client=client,
                model="test-model",
            ))
        self.assertTrue(result["ok"])
        self.assertGreaterEqual(result["coverage"]["read_files"], 5)
        self.assertGreaterEqual(len(client.calls), 3)
        self.assertIn("múltiplas passagens", result["block"].lower())
        self.assertIn("app/routes/auth.py", result["coverage"]["read_paths"])
        self.assertIn(result["coverage"]["status"], {"partial", "reviewed_selected_files"})

    def test_append_hook_skips_regular_targeted_fix(self):
        client = FakeModelClient()
        context = asyncio.run(append_deep_review_if_requested(
            "contexto original", self.project_id, "Corrija o bug do login",
            model_client=client, model="test-model",
        ))
        self.assertEqual(context, "contexto original")
        self.assertEqual(client.calls, [])


if __name__ == "__main__":
    unittest.main()
