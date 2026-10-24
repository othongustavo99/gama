"""Fase 3: prompts, mídia estruturada, variações e indicadores sem cobranças reais."""
import importlib
import json
import os
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from app.core.image_gen import build_image_prompt, ImageIntent
from app.core.prompts import build_system_prompt
from app.core.media_prompt_director import refine_media_brief
from app.models import ChatRequest, ChatMessage

chat_route = importlib.import_module("app.routes.chat")


class ModularPromptsTests(unittest.TestCase):
    def test_casual_prompt_does_not_carry_zip_or_code(self):
        hello = build_system_prompt(web_enabled=False)
        self.assertNotIn("[[GAMA_FILES]]", hello)
        self.assertNotIn("CODE ANALYZER / ENGENHARIA", hello)
        self.assertLess(len(hello), 2200)
        code = build_system_prompt(web_enabled=False, programming_mode=True)
        files = build_system_prompt(web_enabled=False, artifacts_requested=True)
        self.assertIn("CODE ANALYZER / ENGENHARIA", code)
        self.assertIn("[[GAMA_FILES]]", files)
        self.assertGreater(len(code), len(hello))

    def test_memoria_e_modos_permanecem(self):
        prompt = build_system_prompt(memory_block="Apelido: Gus", work_mode=True)
        self.assertIn("Apelido: Gus", prompt)
        self.assertIn("ASSISTÊNCIA UNIVERSAL", prompt)
        self.assertNotIn("[[GAMA_FILES]]", prompt)

    def test_criacao_preserva_estilo_noturno_ou_texto_literal(self):
        prompt = build_image_prompt("Crie uma arte neon noturna com o texto 'Gama'", ImageIntent.GENERATE)
        self.assertIn("neon", prompt)
        self.assertIn("Gama", prompt)
        self.assertNotIn("natural lighting", prompt)
        self.assertNotIn("no text overlays", prompt)

    def test_campos_estruturados_video(self):
        req = ChatRequest(model="x", messages=[ChatMessage(role="user", content="um vídeo")],
                          chat_mode="oficina_video", video_duration=10,
                          video_resolution="720p", video_aspect_ratio="9:16", video_generate_audio=False)
        self.assertEqual(req.video_duration, 10)
        self.assertEqual(req.video_resolution, "720p")
        self.assertFalse(req.video_generate_audio)


class MediaDirectorTests(unittest.IsolatedAsyncioTestCase):
    async def test_disabled_keeps_exact_brief(self):
        with patch.object(chat_route.app_settings, "GAMA_MEDIA_PROMPT_DIRECTOR_ENABLED", False):
            original = "Neon roxo com placa literal em português"
            self.assertEqual(await refine_media_brief(original, kind="image"), original)

    async def test_long_prompt_is_not_rewritten(self):
        long_original = "gato azul " * 60
        self.assertEqual(await refine_media_brief(long_original, kind="image"), long_original.strip())


class VideoOfficeStructuredTests(unittest.IsolatedAsyncioTestCase):
    async def test_selectors_are_passed_to_video_provider(self):
        async def fake_llm(*, model, messages):
            yield json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}) + "\n"

        video_calls = []
        async def fake_video(*args, **kwargs):
            video_calls.append(kwargs)
            yield {"type": "phase", "phase": "video_generating"}
            yield {"type": "completed", "data": b"fake-mp4", "model": "fake", "cost": 0}

        request = ChatRequest(
            model="openai/gpt-5.4-mini", chat_mode="oficina_video",
            video_duration=10, video_resolution="720p",
            video_aspect_ratio="9:16", video_generate_audio=False,
            messages=[ChatMessage(role="user", content="Crie um vídeo de gato andando")],
            auto_memory=False, plugins={"memory": False, "web_search": False, "video_gen": True},
        )
        with tempfile.TemporaryDirectory() as tmp:
            with (
                patch.dict(os.environ, {"DATA_DIR": tmp}),
                patch.object(chat_route.app_settings, "AGENT_TOOLS_ENABLED", False),
                patch.object(chat_route.app_settings, "VIDEO_GEN_ENABLED", True),
                patch.object(chat_route.app_settings, "GAMA_MEDIA_PROMPT_DIRECTOR_ENABLED", False),
                patch.object(chat_route.gama, "build_messages", new=AsyncMock(return_value=(
                    [{"role": "user", "content": "Crie um vídeo de gato andando"}], None, None, []
                ))),
                patch.object(chat_route.llm, "stream_chat", new=fake_llm),
                patch.object(chat_route, "generate_video_events", new=fake_video),
                patch.object(chat_route, "consume_daily_media_quota", return_value=None),
                patch.object(chat_route, "schedule_summary_refresh", return_value=None),
                patch.object(chat_route, "save_artifact", return_value={
                    "artifact_id": "cafebabecafebabe", "filename": "video.mp4", "kind": "video", "size": 8,
                }),
            ):
                response = await chat_route.chat(request, user_id="test-video-structured")
                events = []
                async for data in response.body_iterator:
                    events.extend(json.loads(line) for line in data.splitlines() if line.strip())
        self.assertEqual(len(video_calls), 1)
        kw = video_calls[0]
        self.assertEqual(kw["duration"], 10)
        self.assertEqual(kw["resolution"], "720p")
        self.assertEqual(kw["aspect_ratio"], "9:16")
        self.assertIs(kw["generate_audio"], False)
        self.assertTrue(any((e.get("gama_meta") or {}).get("phase") == "artifact_ready" for e in events))


class PerFileProgressTests(unittest.IsolatedAsyncioTestCase):
    async def test_reports_actual_completed_files(self):
        from app.core.file_bundle import generate_files_per_file
        events = []

        async def fake_chat(messages):
            content = messages[-1]["content"]
            if "Liste SOMENTE os caminhos" in content:
                return {"text": "[[GAMA_PLAN]]\nlib/a.dart\nlib/b.dart\n[[/GAMA_PLAN]]", "finish_reason": "stop"}
            name = "lib/a.dart" if "lib/a.dart" in content else "lib/b.dart"
            return {"text": f"[[GAMA_FILES]]\npath: {name}\n````dart\nvoid main() {{}}\n````\n[[/GAMA_FILES]]", "finish_reason": "stop"}

        result = await generate_files_per_file(fake_chat, [],
            progress_callback=lambda completed, total, path: events.append((completed, total, path)))
        self.assertEqual([e[:2] for e in events], [(1, 2), (2, 2)])
        self.assertEqual(len(result["paths"]), 2)
        self.assertIn("path: lib/a.dart", result["bundle"])
        self.assertIn("path: lib/b.dart", result["bundle"])


if __name__ == "__main__":
    unittest.main()
