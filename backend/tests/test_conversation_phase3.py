"""Fase 3: manifest enxuto, revisões e proteção contra falhas de gravação."""
import os
import tempfile
import unittest
from unittest.mock import patch

from app.core.conversations import ConversationStore


class Phase3SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"DATA_DIR": self.tmp.name})
        self.env.start()
        self.store = ConversationStore("phase3")

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_manifest_omits_messages_but_exposes_revision(self):
        self.store.upsert({"id": "long", "messages": [
            {"id": "a", "role": "user", "content": "X" * 200_000}
        ]})
        lightweight = self.store.list_conversations(include_messages=False)[0]
        self.assertEqual(lightweight["messageCount"], 1)
        self.assertNotIn("messages", lightweight)
        self.assertEqual(len(lightweight["syncRevision"]), 32)
        self.assertLess(len(str(lightweight)), 2000)

    def test_revision_changes_for_messages_metadata_and_deletes(self):
        original = self.store.upsert({"id": "c", "title": "Primeira", "messages": []})
        r1 = original["syncRevision"]
        changed_message = self.store.upsert_message(
            "c", {}, {"id": "a", "role": "user", "content": "Oi"}
        )
        r2 = changed_message["syncRevision"]
        self.assertNotEqual(r1, r2)
        self.store.update_metadata("c", {"title": "Segunda"})
        r3 = self.store.get("c")["syncRevision"]
        self.assertNotEqual(r2, r3)
        self.store.delete_messages("c", ["a"])
        r4 = self.store.get("c")["syncRevision"]
        self.assertNotEqual(r3, r4)
        self.assertIn("a", self.store.get("c")["deletedMessageIds"])

    def test_failed_write_does_not_publish_revision(self):
        self.store.upsert({"id": "safe", "messages": []})
        before = self.store.get("safe")["syncRevision"]
        with patch.object(self.store, "_atomic_json_write", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.store.update_metadata("safe", {"title": "failed"})
        self.assertEqual(before, self.store.get("safe")["syncRevision"])

    def test_legacy_without_revision_remains_readable(self):
        self.store.upsert({"id": "old", "messages": []})
        path = self.store._conversation_path("old")
        import json
        data = json.loads(path.read_text(encoding="utf-8"))
        data.pop("syncRevision")
        path.write_text(json.dumps(data), encoding="utf-8")
        self.assertNotIn("syncRevision", self.store.get("old"))
        self.assertIn("id", self.store.list_conversations(include_messages=False)[0])

class Phase3SyncRouteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {
            "DATA_DIR": self.tmp.name,
            "GAMA_REQUIRE_AUTH": "0",
        })
        self.env.start()
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        from app.routes.conversations import router
        app = FastAPI()
        app.include_router(router)
        self.client = TestClient(app)
        self.headers = {"X-User-Id": "phase3_api_user"}

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_delta_only_returns_changed_conversations_and_tombstones(self):
        payload = {"id": "c", "messages": [
            {"id": "m", "role": "user", "content": "X" * 5000}
        ]}
        response = self.client.put('/conversations/c', json=payload, headers=self.headers)
        self.assertEqual(response.status_code, 200)
        first = self.client.post('/conversations/sync/pull', json={"known": {}}, headers=self.headers)
        self.assertEqual(first.status_code, 200)
        token = first.json()['revisions']['c']
        self.assertEqual(first.json()['conversations'][0]['messages'][0]['id'], 'm')
        empty = self.client.post('/conversations/sync/pull', json={"known": {"c": token}}, headers=self.headers)
        self.assertEqual(empty.status_code, 200)
        self.assertEqual(empty.json()['conversations'], [])
        self.assertEqual(empty.json()['revisions']['c'], token)
        self.client.post('/conversations/c/messages/delete', json={"ids": ["m"]}, headers=self.headers)
        after_delete = self.client.post('/conversations/sync/pull', json={"known": {"c": token}}, headers=self.headers)
        self.assertEqual(after_delete.status_code, 200)
        conv = after_delete.json()['conversations'][0]
        self.assertEqual(conv['messages'], [])
        self.assertIn('m', conv['deletedMessageIds'])
        self.assertNotEqual(after_delete.json()['revisions']['c'], token)

    def test_delta_is_scoped_to_authenticated_user(self):
        self.client.put('/conversations/c', json={"id": "c", "messages": []}, headers=self.headers)
        other = self.client.post('/conversations/sync/pull', json={"known": {}},
                                 headers={"X-User-Id": "another_user"})
        self.assertEqual(other.status_code, 200)
        self.assertEqual(other.json()['conversations'], [])


if __name__ == "__main__":
    unittest.main()
