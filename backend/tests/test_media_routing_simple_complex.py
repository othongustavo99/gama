"""Pedidos de mídia: roteamento sem cobranças reais, com e sem tool calling."""
import importlib
import json
import unittest
from unittest.mock import AsyncMock, patch

from app.core.image_gen import ImageIntent, detect_image_intent, parse_image_aspect_ratio
from app.core.video_gen import VideoIntent, detect_video_intent, parse_video_options
from app.models import ChatImage, ChatMessage, ChatRequest

chat_route = importlib.import_module("app.routes.chat")


def select(text, mode="conversar", *, image=False, video=False):
    return chat_route._media_route_for_turn(
        mode, text, has_images=image, has_video=video,
    )


class MediaIntentMatrix(unittest.TestCase):
    def test_image_simple_complex_and_formats(self):
        cases = (
            "Crie uma imagem de Saturno",
            "Faz uma foto de um astronauta",
            "Desenhe um dragão",
            "Quero um logo de Saturno",
            "Uma foto de uma galáxia",
            "Uma capa de livro de mistério",
            "No começo, pense num universo vasto. Depois descreva a poeira cósmica. "
            + "Estrelas muito pequenas e um planeta central. " * 100
            + "Finalmente, crie uma imagem da cena acima em estilo pintura a óleo.",
        )
        for message in cases:
            with self.subTest(message=message[:60]):
                self.assertEqual(select(message), ("generate_image", "generate"))
        self.assertEqual(select("Crie uma foto vertical em 9:16"), ("generate_image", "generate"))
        self.assertEqual(parse_image_aspect_ratio("Faça um retrato vertical 9:16"), "9:16")
        self.assertEqual(parse_image_aspect_ratio("Uma paisagem horizontal"), "16:9")

    def test_video_simple_complex_and_formats(self):
        cases = (
            "Crie um vídeo de Saturno girando",
            "Faz um clipe de um gato",
            "Quero uma animação de um foguete",
            "Um vídeo vertical de um foguete",
            "Um vídeo de Saturno em que a câmera gire e corte para a lua",
            "Introdução: deserto à noite, poeira brilhante, dois viajantes e um robô. "
            + "A câmera avança pelas dunas até uma estação. " * 100
            + "No fim crie um vídeo vertical de 8 segundos com este roteiro.",
        )
        for message in cases:
            with self.subTest(message=message[:60]):
                self.assertEqual(select(message), ("generate_video", "create"))
        opts = parse_video_options("Crie um clipe vertical de 8 segundos sem áudio")
        self.assertEqual(opts["duration"], 8)
        self.assertEqual(opts["aspect_ratio"], "9:16")
        self.assertFalse(opts["generate_audio"])

    def test_edits_references_and_cross_mode(self):
        cases = (
            ("Anime essa imagem", False, ("generate_video", "animate")),
            ("Crie um vídeo dessa imagem", True, ("generate_video", "animate")),
            ("Quero que a imagem se mexa", True, ("generate_video", "animate")),
            ("Melhore essa foto", True, ("generate_image", "improve")),
            ("Remova o fundo desta imagem", True, ("generate_image", "edit")),
            ("Faz um pouco mais simples e minimalista", True, ("generate_image", "edit")),
            ("Troca a cor do fundo", True, ("generate_image", "edit")),
            ("Edite este vídeo", False, ("generate_video", "edit")),
        )
        for prompt, image, expected in cases:
            with self.subTest(prompt=prompt):
                self.assertEqual(select(prompt, image=image), expected)
        self.assertEqual(select("Uma praia à noite", "oficina_imagem"), ("generate_image", "generate"))
        self.assertEqual(select("Faz um pouco mais simples e minimalista", "oficina_imagem"), ("generate_image", "edit"))
        self.assertEqual(select("Um trem na montanha", "oficina_video"), ("generate_video", "create"))
        self.assertEqual(select("Crie um vídeo de um lago", "oficina_imagem"), ("generate_video", "create"))
        self.assertEqual(select("Crie uma imagem de um lago", "oficina_video"), ("generate_image", "generate"))
        self.assertEqual(select("Uma praia à noite", "oficina_programar"), None)
        self.assertEqual(select("Crie uma imagem de um gato com a palavra 'vídeo'", "conversar"), ("generate_image", "generate"))
        self.assertEqual(select("Crie um vídeo com aparência de imagem vintage"), ("generate_video", "create"))

    def test_questions_and_code_never_trigger_paid_generation(self):
        for question in (
            "Como criar um vídeo?",
            "Como melhorar a qualidade desta imagem?",
            "Você consegue criar vídeos?",
            "Não crie imagem; apenas explique como faria.",
            "Faça um script Python para gerar imagens",
            "Crie um código Flutter para gerar vídeos",
            "Crie um app de editor de fotos",
            "Analise esta imagem",
            "Me dê ideias para gerar vídeos",
        ):
            with self.subTest(question=question):
                self.assertIsNone(select(question, image=True))
        self.assertIsNone(select("Como posso gerar um vídeo?", "oficina_video"))
        self.assertIsNone(select("Analise esta foto", "oficina_imagem", image=True))
        self.assertIsNone(select("Oi, tudo bem?", "oficina_imagem"))


class MediaGenerationStreamTests(unittest.IsolatedAsyncioTestCase):
    async def _stream(self, prompt, *, mode="conversar", images=None, plugins=None, ratio=None):
        request = ChatRequest(
            model="openai/gpt-5.4-mini", chat_mode=mode,
            image_aspect_ratio=ratio,
            images=images,
            auto_memory=False,
            plugins={"web_search": False, "memory": False, **(plugins or {})},
            messages=[ChatMessage(role="user", content=prompt)],
        )
        response = await chat_route.chat(request, user_id="media-routing-regression")
        chunks = []
        async for chunk in response.body_iterator:
            chunks.extend(json.loads(line) for line in chunk.splitlines() if line.strip())
        return chunks

    async def test_normal_chat_generates_detailed_image_with_ratio_and_no_extra_vision(self):
        prompt = ("Crie uma imagem vertical 9:16 de uma cidade noturna. "
                  + "Postes e carros em cores vermelhas. " * 100
                  + "Inclua exatamente o texto 'Gamma' na fachada do prédio principal.")
        async def fake_stream(*, model, messages):
            yield json.dumps({"message": {"role": "assistant", "content": "fallback"}, "done": True}) + "\n"
        image = {"ok": True, "mime": "image/png", "base64": "aGVsbG8=", "model": "fake"}
        with (
            patch.object(chat_route.app_settings, "AGENT_TOOLS_ENABLED", False),
            patch.object(chat_route.app_settings, "IMAGE_GEN_ENABLED", True),
            patch.object(chat_route.gama, "build_messages", new=AsyncMock(return_value=([{"role": "user", "content": prompt}], None, None, []))),
            patch.object(chat_route.llm, "stream_chat", new=fake_stream),
            patch.object(chat_route, "generate_image", new=AsyncMock(return_value=image)) as generator,
            patch.object(chat_route, "refine_media_brief", new=AsyncMock(side_effect=lambda p, **k: p)),
            patch.object(chat_route, "consume_daily_media_quota", return_value=None),
            patch.object(chat_route, "schedule_summary_refresh", return_value=None),
            patch("app.core.image_analyzer.analyze_images", new=AsyncMock()) as analyzer,
        ):
            events = await self._stream(prompt, images=[ChatImage(data="aGVsbG8=", mime="image/png")])
        generator.assert_awaited_once()
        self.assertEqual(generator.await_args.kwargs["aspect_ratio"], "9:16")
        self.assertIsNone(generator.await_args.kwargs["reference_images"])
        self.assertIn("Gamma", generator.await_args.args[0])
        self.assertGreater(len(generator.await_args.args[0]), 3000)
        analyzer.assert_not_awaited()
        self.assertTrue(any((e.get("gama_meta") or {}).get("phase") == "image_ready" for e in events))
        self.assertFalse(any("fallback" in str(e) for e in events))

    async def test_normal_chat_generates_video_once_and_delivers_artifact(self):
        prompt = "Crie um vídeo vertical de 8 segundos de um foguete indo para Saturno, sem som."
        async def mock_video_events(prompt, **kwargs):
            yield {"type": "phase", "phase": "video_generating"}
            yield {"type": "completed", "model": "fake", "cost": 0.02,
                   "data": b"\x00\x00\x00\x18ftyp" + b"0" * 180}
        async def fake_stream(*, model, messages):
            yield json.dumps({"message": {"role": "assistant", "content": "fallback"}, "done": True}) + "\n"
        with (
            patch.object(chat_route.app_settings, "AGENT_TOOLS_ENABLED", False),
            patch.object(chat_route.app_settings, "VIDEO_GEN_ENABLED", True),
            patch.object(chat_route.gama, "build_messages", new=AsyncMock(return_value=([{"role": "user", "content": prompt}], None, None, []))),
            patch.object(chat_route.llm, "stream_chat", new=fake_stream),
            patch.object(chat_route, "generate_video_events", new=mock_video_events),
            patch.object(chat_route, "save_artifact", return_value={"artifact_id": "a123456789abcde0", "filename": "generated.mp4", "size": 188}),
            patch.object(chat_route, "create_job", return_value={"job_id": "test-job-id"}),
            patch.object(chat_route, "get_job", return_value={"provider_job_id": "mock"}),
            patch.object(chat_route, "update_job"),
            patch.object(chat_route, "consume_daily_media_quota", return_value=None),
            patch.object(chat_route, "schedule_summary_refresh", return_value=None),
            patch.object(chat_route, "refine_media_brief", new=AsyncMock(side_effect=lambda p, **k: p)),
        ):
            events = await self._stream(prompt)
        self.assertTrue(any((e.get("gama_meta") or {}).get("phase") == "artifact_ready" for e in events))
        self.assertTrue(any("Vídeo criado" in str(e) for e in events))
        self.assertFalse(any("fallback" in str(e) for e in events))

    async def test_reference_required_does_not_charge(self):
        message = "Anime essa imagem e faça a pessoa andar"
        with (
            patch.object(chat_route.app_settings, "AGENT_TOOLS_ENABLED", False),
            patch.object(chat_route.gama, "build_messages", new=AsyncMock(return_value=([{"role": "user", "content": message}], None, None, []))),
            patch.object(chat_route, "consume_daily_media_quota") as quota,
            patch.object(chat_route, "generate_video_events") as generator,
            patch.object(chat_route, "schedule_summary_refresh", return_value=None),
        ):
            events = await self._stream(message)
        self.assertTrue(any("anexe a imagem" in str(e) for e in events))
        generator.assert_not_called()
        quota.assert_not_called()


if __name__ == "__main__":
    unittest.main()

class VideoProviderDownloadTests(unittest.IsolatedAsyncioTestCase):
    async def test_openrouter_content_url_uses_auth_and_external_uses_none(self):
        from app.core.video_gen import fetch_generated_video
        video_bytes = b"\x00\x00\x00\x18ftyp" + b"0" * 180
        class Response:
            status_code = 200
            headers = {"content-type": "video/mp4"}
            async def aiter_bytes(self):
                yield video_bytes
        class Stream:
            async def __aenter__(self):
                return Response()
            async def __aexit__(self, *args):
                return None
        class Client:
            def __init__(self):
                self.calls = []
            def stream(self, method, url, *, headers, follow_redirects):
                self.calls.append((url, headers, follow_redirects))
                return Stream()
        client = Client()
        key = {"Authorization": "Bearer secret-token"}
        with patch("app.core.video_gen.validate_public_url", new=AsyncMock(return_value=None)):
            _, status, mime, body = await fetch_generated_video(
                client, "https://openrouter.ai/api/v1/videos/job-abcd/content?index=0",
                job_id="job-abcd", headers=key,
            )
        self.assertEqual(status, 200)
        self.assertEqual(body, video_bytes)
        self.assertEqual(client.calls[0][1], key)

        external = AsyncMock(return_value=("https://cdn.example/video.mp4", 200, "video/mp4", video_bytes))
        await fetch_generated_video(
            client, "https://cdn.example/video.mp4",
            job_id="job-abcd", headers=key, fetch_external=external,
        )
        self.assertEqual(external.await_args.args[1], "https://cdn.example/video.mp4")
        self.assertNotIn("headers", external.await_args.kwargs)

    async def test_missing_url_falls_back_to_authenticated_content_endpoint(self):
        from app.core.video_gen import fetch_generated_video
        class Response:
            status_code = 200
            headers = {"content-type": "video/mp4"}
            async def aiter_bytes(self):
                yield b"\x00\x00\x00\x18ftyp" + b"0" * 180
        class Stream:
            async def __aenter__(self): return Response()
            async def __aexit__(self, *args): pass
        class Client:
            def stream(self, method, url, **kwargs):
                self.url, self.headers = url, kwargs["headers"]
                return Stream()
        client = Client()
        with patch("app.core.video_gen.validate_public_url", new=AsyncMock(return_value=None)):
            await fetch_generated_video(client, "", job_id="job-abcd", headers={"Authorization": "Bearer xxx"})
        self.assertEqual(client.url, "https://openrouter.ai/api/v1/videos/job-abcd/content?index=0")
        self.assertIn("Authorization", client.headers)

    async def test_authenticated_redirect_does_not_forward_auth(self):
        from app.core.video_gen import fetch_generated_video
        class Response:
            status_code = 302
            headers = {"location": "https://video-cdn.example.com/clip.mp4"}
        class Stream:
            async def __aenter__(self): return Response()
            async def __aexit__(self, *args): pass
        class Client:
            def stream(self, method, url, **kwargs): return Stream()
        external = AsyncMock(return_value=("https://video-cdn.example.com/clip.mp4", 200, "video/mp4", b"data"))
        with patch("app.core.video_gen.validate_public_url", new=AsyncMock(return_value=None)):
            await fetch_generated_video(
                Client(), "https://openrouter.ai/api/v1/videos/job-aaaa/content",
                job_id="job-aaaa", headers={"Authorization": "Bearer secret"},
                fetch_external=external,
            )
        self.assertEqual(external.await_args.args[1], "https://video-cdn.example.com/clip.mp4")
        self.assertNotIn("headers", external.await_args.kwargs)
