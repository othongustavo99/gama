"""Phase 1: selected models and artifact metadata survive conversation sync."""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from unittest.mock import patch

from app.config import Settings
from app.core.conversations import ConversationStore
from app.routes.chat import _safe_artifacts_json, _resolve_chat_model
from app.routes.conversations import MessageIn


class Phase1ModelsArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"DATA_DIR": self.tmp.name})
        self.env.start()
        self.store = ConversationStore('phase1_user')

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_both_normal_modes_are_allowed(self):
        self.assertIn(Settings.CONVERSATION_MODEL, Settings().allowed_models)
        self.assertIn(Settings.CODING_MODEL, Settings().allowed_models)

    def test_router_chooses_model_by_mode(self):
        with patch('app.routes.chat.llm.resolve_model', side_effect=lambda m: m):
            self.assertEqual(_resolve_chat_model('anything', 'conversar'), Settings.CONVERSATION_MODEL)
            self.assertEqual(_resolve_chat_model('anything', 'programar'), Settings.CODING_MODEL)
            self.assertEqual(_resolve_chat_model('anything', 'trabalhar'), Settings.CODING_MODEL)
            self.assertEqual(_resolve_chat_model('anything', 'oficina_programar'), Settings.OFICINA_CODING_MODEL)
            self.assertEqual(_resolve_chat_model('custom', 'oficina_imagem'), 'custom')

    def test_artifact_metadata_round_trip_with_message_upsert(self):
        meta = [{'artifact_id': 'video_abc123', 'kind': 'video', 'filename': 'video.mp4'}]
        payload = {'id': 'chat', 'messages': [
            {'id': 'assistant', 'role': 'assistant', 'content': 'Vídeo pronto',
             'artifactsJson': json.dumps(meta), 'sourcesJson': ''},
        ]}
        self.store.upsert(payload)
        saved = self.store.get('chat')['messages'][0]
        self.assertEqual(json.loads(saved['artifactsJson']), meta)
        self.store.upsert_message('chat', {}, dict(saved, content='Vídeo pronto.'))
        self.assertEqual(json.loads(self.store.get('chat')['messages'][0]['artifactsJson']), meta)

    def test_old_messages_without_artifacts_still_work(self):
        self.store.upsert({'id': 'old', 'messages': [
            {'id': 'old_ai', 'role': 'assistant', 'content': 'Antiga resposta'}
        ]})
        self.assertEqual(self.store.get('old')['messages'][0]['content'], 'Antiga resposta')

    def test_schema_accepts_artifact_metadata_and_rejects_oversized(self):
        msg = MessageIn(id='reply', role='assistant', content='Arquivo pronto', artifactsJson='[]')
        self.assertEqual(msg.artifactsJson, '[]')
        from pydantic import ValidationError
        with self.assertRaises(ValidationError):
            MessageIn(id='reply', role='assistant', content='Arquivo pronto', artifactsJson='X'*100001)

    def test_background_recovery_metadata_is_valid_json(self):
        long_metadata = [{'artifact_id': 'abc123', 'filename': 'files.zip',
                          'kind': 'zip', 'generated_files': ['x' * 60000, 'y' * 60000]}]
        encoded = _safe_artifacts_json(long_metadata)
        self.assertLessEqual(len(encoded), 100000)
        self.assertEqual(json.loads(encoded)[0]['artifact_id'], 'abc123')


if __name__ == '__main__':
    unittest.main()
