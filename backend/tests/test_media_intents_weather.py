import unittest
from unittest.mock import patch

from app.core.agent import build_tools
from app.core.image_gen import ImageIntent, detect_image_intent
from app.core.video_gen import VideoIntent, detect_video_intent, parse_video_options
from app.core.video_analysis import validate_video_reference_duration
from app.core.weather import _weather_label, format_weather_for_model, get_weather_report


class MediaIntentTests(unittest.TestCase):
    def test_video_create_and_analyze_are_distinct(self):
        self.assertEqual(
            detect_video_intent("Crie um vídeo de um dragão voando").intent,
            VideoIntent.CREATE,
        )
        self.assertEqual(
            detect_video_intent("Analise este vídeo", has_attached_video=True).intent,
            VideoIntent.ANALYZE,
        )
        self.assertEqual(
            detect_video_intent("Crie um vídeo com esta imagem", has_attached_images=True).intent,
            VideoIntent.ANIMATE,
        )
        self.assertEqual(
            detect_video_intent("Crie um vídeo de um dragão voando", has_attached_images=True).intent,
            VideoIntent.CREATE,
        )
        self.assertEqual(
            detect_video_intent("Crie um vídeo a partir do anexo", has_attached_images=True).intent,
            VideoIntent.ANIMATE,
        )

    def test_video_attachment_metadata_does_not_override_real_request(self):
        automatic_label = "[video_artifact_id:0123456789abcdef]\nVídeo anexado: clipe.mp4."
        self.assertEqual(
            detect_video_intent(
                automatic_label,
                has_attached_video=True,
            ).intent,
            VideoIntent.ANALYZE,
        )
        self.assertEqual(
            detect_video_intent(
                "Crie uma imagem de um gato\n" + automatic_label,
                has_attached_video=True,
            ).intent,
            VideoIntent.NONE,
        )
        self.assertEqual(
            detect_video_intent(
                "Vai chover hoje?\n" + automatic_label,
                has_attached_video=True,
            ).intent,
            VideoIntent.NONE,
        )

    def test_video_edit_improve_and_advice_are_distinct(self):
        self.assertEqual(
            detect_video_intent("Edite este vídeo e remova o início", has_attached_video=True).intent,
            VideoIntent.EDIT,
        )
        self.assertEqual(
            detect_video_intent("Melhore a qualidade deste vídeo", has_attached_video=True).intent,
            VideoIntent.IMPROVE,
        )
        self.assertEqual(
            detect_video_intent("O que posso melhorar neste vídeo?", has_attached_video=True).intent,
            VideoIntent.ANALYZE,
        )
        self.assertEqual(
            detect_video_intent("Como editar vídeos no Premiere?").intent,
            VideoIntent.NONE,
        )

    def test_image_intent_advice_does_not_edit(self):
        self.assertEqual(
            detect_image_intent("O que posso melhorar nesta imagem?", has_attached_images=True).intent,
            ImageIntent.ANALYZE,
        )
        self.assertEqual(
            detect_image_intent("Melhore esta imagem", has_attached_images=True).intent,
            ImageIntent.IMPROVE,
        )
        self.assertEqual(
            detect_image_intent("Crie uma imagem de um gato").intent,
            ImageIntent.GENERATE,
        )

    def test_video_reference_duration_is_checked_before_provider_call(self):
        validate_video_reference_duration(2)
        validate_video_reference_duration(15)
        with self.assertRaisesRegex(ValueError, "pelo menos 2 segundos"):
            validate_video_reference_duration(1.5)
        with self.assertRaisesRegex(ValueError, "até 15 segundos"):
            validate_video_reference_duration(30)

    def test_video_generation_respects_disabled_feature_flag(self):
        import asyncio
        from app.core.video_gen import generate_video_events

        async def collect():
            return [event async for event in generate_video_events("test")]

        with patch("app.core.video_gen.settings.VIDEO_GEN_ENABLED", False):
            events = asyncio.run(collect())
        self.assertEqual(events[0]["type"], "error")
        self.assertIn("desativada", events[0]["error"])

    def test_video_options_are_bounded_and_follow_orientation(self):
        options = parse_video_options("Crie um vídeo vertical HD de 8 segundos")
        self.assertEqual(options["duration"], 8)
        self.assertEqual(options["resolution"], "720p")
        self.assertEqual(options["aspect_ratio"], "9:16")
        self.assertLessEqual(
            parse_video_options("Crie um vídeo de 15 segundos")["duration"], 10
        )
        self.assertTrue(parse_video_options("Crie um vídeo de um cachorro na praia")["generate_audio"])
        self.assertFalse(parse_video_options("Crie um vídeo sem som")["generate_audio"])


class WeatherTests(unittest.TestCase):
    def test_open_meteo_tool_is_available_to_agent(self):
        tools = build_tools()
        self.assertTrue(any(t["function"]["name"] == "get_weather" for t in tools))

    def test_weather_code_labels_and_formatting(self):
        self.assertEqual(_weather_label(61), "chuva fraca")
        self.assertIn("condição meteorológica não identificada", _weather_label(999))
        report = {
            "ok": True,
            "location": "Campinas, São Paulo, Brasil",
            "timezone": "America/Sao_Paulo",
            "current": {
                "time": "2026-10-16T16:00", "condition": "céu limpo", "temperature_c": 25,
                "feels_like_c": 26, "humidity_percent": 60, "wind_kmh": 10,
                "precipitation_mm": 0, "rain_mm": 0, "cloud_cover_percent": 10,
            },
            "daily": [],
        }
        formatted = format_weather_for_model(report)
        self.assertIn("Open-Meteo", formatted)
        self.assertIn("Campinas", formatted)
        self.assertIn("25 °C", formatted)

    def test_weather_without_locality_asks_user(self):
        asyncio = __import__("asyncio")
        for location in ("", "aqui", "perto de mim", "minha localização"):
            result = asyncio.run(get_weather_report(location))
            self.assertFalse(result["ok"])
            self.assertIn("cidade", result["error"])


if __name__ == "__main__":
    unittest.main()
