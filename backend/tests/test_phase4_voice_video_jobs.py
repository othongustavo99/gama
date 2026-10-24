"""Phase 4 regression tests: persistent video work and recovery without creating new paid jobs."""
from __future__ import annotations

import asyncio
import os
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from fastapi import HTTPException

from app.core import video_jobs
from app.routes import media


class VideoJobStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.patch = patch.dict(os.environ, {"DATA_DIR": self.temp.name})
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_job_survives_reads_and_isolated_by_user(self):
        created = video_jobs.create_job("alice", conversation_id="chat-123")
        video_jobs.update_job("alice", created["job_id"],
                              provider_job_id="providerId", polling_url="https://openrouter.ai/api/v1/videos/providerId",
                              status="processing")
        self.assertEqual(video_jobs.get_job("alice", created["job_id"])["status"], "processing")
        self.assertIsNone(video_jobs.get_job("bob", created["job_id"]))
        self.assertEqual(len(video_jobs.list_jobs("alice")), 1)
        self.assertNotIn("polling_url", video_jobs.list_jobs("alice")[0])
        self.assertNotIn("provider_job_id", video_jobs.list_jobs("alice")[0])

    def test_bad_job_id_cannot_traverse_directories(self):
        self.assertIsNone(video_jobs.get_job("alice", "../../pass"))
        self.assertIsNone(video_jobs.update_job("alice", "../../pass", status="completed"))


class VideoRecoveryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.patch = patch.dict(os.environ, {"DATA_DIR": self.temp.name})
        self.patch.start()
        self.addCleanup(self.patch.stop)

    async def test_pending_job_rechecks_provider_but_does_not_submit(self):
        created = video_jobs.create_job("alice")
        video_jobs.update_job("alice", created["job_id"],
            status="recoverable", provider_job_id="job1234",
            polling_url="https://openrouter.ai/api/v1/videos/job1234")

        class StubResponse:
            status_code = 200
            def json(self):
                return {"status": "in_progress"}

        class StubClient:
            def __init__(self, *args, **kwargs):
                self.gets = []
            async def __aenter__(self):
                return self
            async def __aexit__(self, *args):
                pass
            async def get(self, *args, **kwargs):
                return StubResponse()

        with patch.object(media.settings, "OPENROUTER_API_KEY", "test-key"), \
             patch.object(media.httpx, "AsyncClient", StubClient):
            result = await media.resume_video_job(created["job_id"], user_id="alice")
        self.assertEqual(result["job"]["status"], "processing")
        self.assertNotIn("polling_url", result["job"])

    async def test_completed_video_is_saved_once(self):
        created = video_jobs.create_job("alice")
        video_jobs.update_job("alice", created["job_id"],
            status="recoverable", provider_job_id="job1234",
            polling_url="https://openrouter.ai/api/v1/videos/job1234")

        class StubResponse:
            status_code = 200
            def json(self):
                return {"status": "completed", "unsigned_urls": ["https://cdn.example.org/video.mp4"]}

        class StubClient:
            def __init__(self, *args, **kwargs):
                pass
            async def __aenter__(self):
                return self
            async def __aexit__(self, *args):
                pass
            async def get(self, *args, **kwargs):
                return StubResponse()

        payload = b"\x00\x00\x00\x18ftyp" + b"0" * 160
        with patch.object(media.settings, "OPENROUTER_API_KEY", "test-key"), \
             patch.object(media.httpx, "AsyncClient", StubClient), \
             patch.object(media, "safe_get", new_callable=AsyncMock) as fetch:
            fetch.return_value = ("https://cdn.example.org/video.mp4", 200, "video/mp4", payload)
            result = await media.resume_video_job(created["job_id"], user_id="alice")
            second = await media.resume_video_job(created["job_id"], user_id="alice")
        self.assertEqual(result["job"]["status"], "completed")
        self.assertRegex(result["job"]["artifact_id"], r"^[0-9a-f]{16}$")
        self.assertEqual(second["job"]["artifact_id"], result["job"]["artifact_id"])
        self.assertEqual(fetch.await_count, 1)

    async def test_refuses_forged_provider_url(self):
        created = video_jobs.create_job("alice")
        video_jobs.update_job("alice", created["job_id"],
            status="recoverable", polling_url="http://169.254.169.254/latest/meta-data")
        with self.assertRaises(HTTPException) as cm:
            await media.resume_video_job(created["job_id"], user_id="alice")
        self.assertEqual(cm.exception.status_code, 409)

    async def test_refuses_cross_account_jobs(self):
        created = video_jobs.create_job("alice")
        with self.assertRaises(HTTPException) as cm:
            await media.resume_video_job(created["job_id"], user_id="bob")
        self.assertEqual(cm.exception.status_code, 404)


if __name__ == "__main__":
    unittest.main()
