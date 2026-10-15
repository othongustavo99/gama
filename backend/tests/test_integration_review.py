from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("DATA_DIR", tempfile.mkdtemp())

from app.core.code_analyzer.index_store import save_meta, workspace  # noqa: E402
from app.core.code_analyzer.integration_review import build_integration_map, render_integration_context  # noqa: E402


class IntegrationReviewTests(unittest.TestCase):
    def setUp(self):
        self.old_data_dir = os.environ.get("DATA_DIR")
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["DATA_DIR"] = self.tmp.name
        self.project_id = "integrationtest"
        self.root = workspace(self.project_id)
        sources = {
            "app/main.py": "from app.routes.auth import login\n\ndef main():\n    return login()\n",
            "app/routes/auth.py": "from app.services.user_service import UserService\n\ndef login():\n    return UserService().get_user()\n",
            "app/services/user_service.py": "from app.repositories.user_repository import UserRepository\n\nclass UserService:\n    def get_user(self):\n        return UserRepository().get()\n",
            "app/repositories/user_repository.py": "class UserRepository:\n    def get(self):\n        return {'id': 1}\n",
            "tests/test_auth.py": "def test_login():\n    assert True\n",
        }
        file_meta = []
        for path, content in sources.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
            file_meta.append({"path": path, "size": len(content), "ext": target.suffix, "important": path.endswith("main.py")})
        save_meta(self.project_id, {
            "name": "integration-test",
            "source": {"type": "zip"},
            "scan_root": ".",
            "map": {"file_count": len(file_meta), "files": file_meta},
        })

    def tearDown(self):
        if self.old_data_dir is None:
            os.environ.pop("DATA_DIR", None)
        else:
            os.environ["DATA_DIR"] = self.old_data_dir
        self.tmp.cleanup()

    def test_import_graph_connects_api_service_and_repository(self):
        report = build_integration_map(self.project_id)
        edges = {(item["from"], item["to"]) for item in report["edges"]}
        self.assertIn(("app/main.py", "app/routes/auth.py"), edges)
        self.assertIn(("app/routes/auth.py", "app/services/user_service.py"), edges)
        self.assertIn(("app/services/user_service.py", "app/repositories/user_repository.py"), edges)
        self.assertGreaterEqual(report["readable_file_count"], 5)

    def test_integration_context_warns_that_test_name_match_is_heuristic(self):
        rendered = render_integration_context(build_integration_map(self.project_id))
        self.assertIn("heurístico", rendered.lower())
        self.assertIn("test_auth.py", rendered)


if __name__ == "__main__":
    unittest.main()
