import io
import json
import os
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.document_builder import apply_edits_and_zip, build_zip_from_files
from app.core.identity import current_user_id
from app.core.memory import get_store
from app.routes.artifacts import router as artifacts_router
from app.routes.chat import _memory_saved_event


class FinalProgrammingFeaturesTest(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        env = patch.dict(os.environ, {"DATA_DIR": folder.name, "GAMA_MEMORY_V3_ENABLED": "true"})
        env.start()
        self.addCleanup(env.stop)

    def test_memory_notice_undoes_the_exact_change_and_ignores_duplicates(self):
        store = get_store("owner")
        fact, added = store.add_fact_with_change("Apelido: Astro")
        self.assertIsNotNone(added["undo_event_id"])
        duplicate, notice = store.add_fact_with_change("Apelido: Astro")
        self.assertEqual(duplicate["id"], fact["id"])
        self.assertIsNone(notice)

        _, updated = store.add_fact_with_change("Apelido: Luna")
        event = json.loads(_memory_saved_event(updated))["gama_meta"]
        self.assertEqual(event["memory_saved"], "Apelido: Luna")
        self.assertNotEqual(event["memory_undo_event_id"], added["undo_event_id"])

        with self.assertRaises(ValueError):
            store.undo_event(added["undo_event_id"])
        store.undo_event(event["memory_undo_event_id"])
        self.assertEqual([item["text"] for item in store.list_facts()], ["Apelido: Astro"])

    def test_zip_files_are_account_scoped_and_download_exact_bytes(self):
        content = "linha da Gamma\n" * 1200
        archive = build_zip_from_files(
            {"lib/codigo.txt": content, "grande.txt": "x" * (1024 * 1024 + 1)},
            filename="codigo.zip",
            user_id="owner",
        )
        base = f"/artifacts/{archive['artifact_id']}/files"
        application = FastAPI()
        application.include_router(artifacts_router)
        application.dependency_overrides[current_user_id] = lambda: "owner"
        with TestClient(application) as client:
            entries = client.get(base).json()["files"]
            by_name = {entry["name"]: entry for entry in entries}
            self.assertEqual(set(by_name), {"lib/codigo.txt", "grande.txt"})
            route = f"{base}/{by_name['lib/codigo.txt']['index']}"
            self.assertEqual(client.get(route).json()["content"], content)
            downloaded = client.get(f"{route}/download")
            self.assertEqual(downloaded.content, content.encode("utf-8"))
            self.assertEqual(int(downloaded.headers["Content-Length"]), len(downloaded.content))
            large = f"{base}/{by_name['grande.txt']['index']}"
            self.assertEqual(client.get(large).json()["reason"], "too_large")
            self.assertEqual(len(client.get(f"{large}/download").content), 1024 * 1024 + 1)

            application.dependency_overrides[current_user_id] = lambda: "another-user"
            self.assertEqual(client.get(base).status_code, 404)
            self.assertEqual(client.get(route).status_code, 404)
            self.assertEqual(client.get(f"{route}/download").status_code, 404)


    def test_edited_zip_exposes_the_existing_file_diff(self):
        original = io.BytesIO()
        with ZipFile(original, "w") as archive:
            archive.writestr("lib/code.txt", "original\n")
        edited = apply_edits_and_zip(
            zip_bytes=original.getvalue(),
            edits=[{"path": "lib/code.txt", "action": "write", "content": "revisado\n"}],
            user_id="owner",
        )
        app = FastAPI()
        app.include_router(artifacts_router)
        app.dependency_overrides[current_user_id] = lambda: "owner"
        with TestClient(app) as client:
            url = f"/artifacts/{edited['artifact_id']}/files"
            index = client.get(url).json()["files"][0]["index"]
            file = client.get(f"{url}/{index}").json()
        self.assertEqual(file["content"], "revisado\n")
        self.assertIn("-original", file["diff"])
        self.assertIn("+revisado", file["diff"])


if __name__ == "__main__":
    unittest.main()
