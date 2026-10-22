"""Fase 1: evita perdas de histórico e preserva modo e exclusões."""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.conversations import ConversationStore
from app.routes.conversations import router


class ConversationStoreSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"DATA_DIR": self.tmp.name})
        self.env.start()
        self.store = ConversationStore("test_account")

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    @staticmethod
    def msg(index: int):
        return {
            "id": f"msg-{index}", "role": "user", "content": f"Mensagem {index}",
            "timestamp": f"2026-01-01T00:{(index // 60) % 60:02d}:{index % 60:02d}Z",
        }

    def test_history_over_500_survives_full_and_incremental_updates(self):
        messages = [self.msg(i) for i in range(550)]
        self.store.upsert({"id": "long", "title": "Original", "mode": "oficina_programar",
                           "updatedAt": "2026-01-02T00:00:00Z", "messages": messages})
        self.assertEqual(len(self.store.get("long")["messages"]), 550)
        # Outro aparelho envia apenas o fim da conversa.
        self.store.upsert({"id": "long", "title": "Atualizada", "mode": "oficina_programar",
                           "updatedAt": "2026-01-03T00:00:00Z", "messages": messages[-30:]})
        self.assertEqual(len(self.store.get("long")["messages"]), 550)
        self.store.upsert_message("long", {}, self.msg(550))
        self.assertEqual(len(self.store.get("long")["messages"]), 551)
        self.assertEqual(self.store.get("long")["messages"][0]["id"], "msg-0")

    def test_older_metadata_cannot_replace_newer_mode(self):
        self.store.upsert({"id": "work", "title": "Oficina", "mode": "oficina_programar",
                           "updatedAt": "2026-06-20T18:00:00Z", "messages": [self.msg(0)]})
        self.store.upsert({"id": "work", "title": "Nome antigo", "isPinned": False,
                           "updatedAt": "2026-06-19T18:00:00Z", "messages": [self.msg(1)]})
        stored = self.store.get("work")
        self.assertEqual(stored["title"], "Oficina")
        self.assertEqual(stored["mode"], "oficina_programar")
        self.assertEqual(len(stored["messages"]), 2)

    def test_metadata_patch_does_not_delete_messages_and_can_clear_mode(self):
        self.store.upsert({"id": "mode", "title": "A", "mode": "oficina_criar",
                           "updatedAt": "2026-02-01T00:00:00Z", "messages": [self.msg(i) for i in range(510)]})
        self.assertTrue(self.store.update_metadata("mode", {"mode": None,
            "updatedAt": "2026-02-02T00:00:00Z"}))
        stored = self.store.get("mode")
        self.assertIsNone(stored["mode"])
        self.assertEqual(len(stored["messages"]), 510)

    def test_delete_tombstones_prevent_resurrection(self):
        self.store.upsert({"id": "delete", "title": "A", "messages": [self.msg(1), self.msg(2)]})
        self.store.delete_messages("delete", ["msg-1"])
        self.store.upsert({"id": "delete", "title": "A", "messages": [self.msg(1), self.msg(2)]})
        result = self.store.get("delete")
        self.assertEqual([x["id"] for x in result["messages"]], ["msg-2"])
        self.assertIn("msg-1", result["deletedMessageIds"])

    def test_many_conversations_are_not_pruned_automatically(self):
        for i in range(205):
            self.store.upsert({"id": f"conv-{i}", "title": "A", "messages": []})
        self.assertEqual(len(self.store.list_conversations()), 205)


class ConversationRouteModeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"DATA_DIR": self.tmp.name, "GAMA_REQUIRE_AUTH": "0"})
        self.env.start()
        self.client = TestClient(FastAPI())
        self.client.app.include_router(router)
        self.headers = {"X-User-Id": "test-route-user"}

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_put_and_patch_mode_round_trip(self):
        put = self.client.put("/conversations/r-1", json={
            "id": "r-1", "title": "Oficina", "mode": "oficina_programar",
            "messages": [{"id":"m1", "role":"user", "content":"Olá"}],
        }, headers=self.headers)
        self.assertEqual(put.status_code, 200, put.text)
        self.assertEqual(put.json()["conversation"]["mode"], "oficina_programar")
        patch_mode = self.client.patch("/conversations/r-1", json={"mode": "oficina_imagem"}, headers=self.headers)
        self.assertEqual(patch_mode.status_code, 200, patch_mode.text)
        got = self.client.get("/conversations/r-1", headers=self.headers)
        self.assertEqual(got.json()["mode"], "oficina_imagem")
        self.assertEqual(len(got.json()["messages"]), 1)
        clear = self.client.patch("/conversations/r-1", json={"mode": None}, headers=self.headers)
        self.assertEqual(clear.status_code, 200)
        self.assertIsNone(self.client.get("/conversations/r-1", headers=self.headers).json()["mode"])


if __name__ == "__main__":
    unittest.main()
