"""Fase 2: testes de recuperação e sincronização, sem provedores externos."""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.conversations import ConversationStore
from app.routes.conversations import router


class ConversationRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.patch = patch.dict(os.environ, {"DATA_DIR": self.tmp.name, "GAMA_REQUIRE_AUTH": "0"})
        self.patch.start()
        self.store = ConversationStore("phase2_test")

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    @staticmethod
    def message(mid, text, timestamp="2026-10-22T09:00:00Z"):
        return {"id": mid, "role": "assistant", "content": text,
                "timestamp": timestamp}

    def test_message_replayed_after_network_failure_does_not_duplicate(self):
        self.store.upsert({"id": "sync", "messages": [self.message("first", "A")]})
        for _ in range(3):
            self.store.upsert_message("sync", {}, self.message("reply", "Recebida"))
        messages = self.store.get("sync")["messages"]
        self.assertEqual({msg["id"] for msg in messages}, {"first", "reply"})
        self.assertEqual(len(messages), 2)

    def test_old_replayed_message_does_not_replace_new_completion(self):
        old = self.message("reply", "Parcial", "2026-10-22T09:00:00Z")
        new = self.message("reply", "Concluída", "2026-10-22T09:00:03Z")
        self.store.upsert_message("reply_chat", {}, new)
        self.store.upsert_message("reply_chat", {}, old)
        self.assertEqual(self.store.get("reply_chat")["messages"][0]["content"], "Concluída")

    def test_write_failure_does_not_erase_last_saved_copy(self):
        self.store.upsert({"id": "safe", "title": "Anterior", "messages": [self.message("x", "Ok")]})
        with patch.object(self.store, "_atomic_json_write", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.store.upsert({"id": "safe", "title": "Nunca gravado", "messages": []})
        stored = self.store.get("safe")
        self.assertEqual(stored["title"], "Anterior")
        self.assertEqual(len(stored["messages"]), 1)

    def test_invalid_json_one_conversation_does_not_hide_others(self):
        self.store.upsert({"id": "safe", "title": "Mantida", "messages": []})
        corrupt = self.store._conversation_path("broken")
        corrupt.write_text("{bad-json", encoding="utf-8")
        self.assertEqual([c["id"] for c in self.store.list_conversations()], ["safe"])
        self.assertEqual(self.store.get("safe")["title"], "Mantida")

    def test_parallel_message_sync_preserves_all_unique_ids(self):
        def send(i):
            self.store.upsert_message("parallel", {}, self.message(f"id-{i}", str(i)))
        with ThreadPoolExecutor(max_workers=6) as executor:
            list(executor.map(send, range(16)))
        self.assertEqual(len(self.store.get("parallel")["messages"]), 16)

    def test_deleted_message_cannot_return_from_delayed_device(self):
        self.store.upsert({"id": "del", "messages": [self.message("gone", "x")]})
        self.store.delete_messages("del", ["gone"])
        self.store.upsert_message("del", {}, self.message("gone", "stale"))
        self.assertEqual(self.store.get("del")["messages"], [])
        self.assertIn("gone", self.store.get("del")["deletedMessageIds"])


class ConversationRouteRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.patch = patch.dict(os.environ, {"DATA_DIR": self.tmp.name, "GAMA_REQUIRE_AUTH": "0"})
        self.patch.start()
        app = FastAPI()
        app.include_router(router)
        self.client = TestClient(app)
        self.headers = {"X-User-Id": "phase2_api_user"}

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def test_sync_http_404_and_invalid_id_can_be_distinguished(self):
        missing = self.client.get("/conversations/missing", headers=self.headers)
        self.assertEqual(missing.status_code, 404)
        wrong = self.client.put("/conversations/other", headers=self.headers,
                                json={"id": "one", "title": "Test", "messages": []})
        self.assertEqual(wrong.status_code, 400)

    def test_delete_message_then_retry_old_payload(self):
        payload = {"id": "retry", "title": "Teste", "mode": "oficina_programar",
                   "messages": [{"id": "a", "role": "user", "content": "teste"}]}
        self.assertEqual(self.client.put("/conversations/retry", json=payload,
                          headers=self.headers).status_code, 200)
        self.assertEqual(self.client.post("/conversations/retry/messages/delete",
                         json={"ids": ["a"]}, headers=self.headers).status_code, 200)
        self.assertEqual(self.client.put("/conversations/retry", json=payload,
                         headers=self.headers).status_code, 200)
        got = self.client.get("/conversations/retry", headers=self.headers).json()
        self.assertEqual(got["messages"], [])
        self.assertEqual(got["mode"], "oficina_programar")


if __name__ == "__main__":
    unittest.main()
