"""Regressão: "versão humana" não exige uma imagem anterior."""
import unittest

from app.core.image_gen import ImageIntent, detect_image_intent, generate_image
from app.routes.chat import _office_media_action


class ImageCreationIntentRegressionTests(unittest.TestCase):
    def test_novas_imagens_sao_criadas_do_zero(self):
        for prompt in (
            "Faz assim, crie uma foto sua em versão humana",
            "Crie uma foto de uma mulher em versão cyberpunk",
            "Crie uma imagem de um gato e adicione um chapéu vermelho",
            "Crie uma versão humana da Gamma",
        ):
            with self.subTest(prompt=prompt):
                self.assertEqual(detect_image_intent(prompt).intent, ImageIntent.GENERATE)
                self.assertEqual(
                    _office_media_action('oficina_imagem', prompt, has_images=False, has_video=False),
                    'generate',
                )

    def test_edicao_de_referencia_explicita_continua_funcionando(self):
        for prompt in (
            'Crie outra versão dessa imagem em anime',
            'Faça uma variação da foto anterior',
            'Edite esta imagem',
            'Modifique a imagem anterior para ficar azul',
        ):
            with self.subTest(prompt=prompt):
                self.assertEqual(
                    _office_media_action('oficina_imagem', prompt, has_images=False, has_video=False),
                    'edit',
                )

    def test_transformar_ideia_nao_exige_imagem_existente(self):
        self.assertEqual(
            _office_media_action('oficina_imagem', 'Transforme minha ideia de jardim em uma ilustração',
                                 has_images=False, has_video=False),
            'generate',
        )

    def test_analise_nao_deve_ser_geracao(self):
        self.assertNotEqual(detect_image_intent('Faz uma análise desta foto', True).intent, ImageIntent.GENERATE)
        self.assertIsNone(_office_media_action('oficina_imagem', 'Faça uma análise da imagem',
                                                has_images=True, has_video=False))

    def test_pergunta_nao_inicia_geracao(self):
        self.assertIsNone(_office_media_action('oficina_imagem', 'Como crio uma imagem?',
                                               has_images=False, has_video=False))

# Exercita a rota de fato: pedido sem imagem de entrada deve chegar a
# generate_image(reference_images=None), sem gerar cobrança real.
import importlib
import json
from unittest.mock import AsyncMock, patch
from app.models import ChatRequest, ChatMessage

chat_route = importlib.import_module('app.routes.chat')


class ImageCreationStreamRegressionTests(unittest.IsolatedAsyncioTestCase):
    async def test_oficina_text_to_image_nao_exige_anexo(self):
        async def fake_llm_stream(*, model, messages):
            yield json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}) + "\n"

        request = ChatRequest(
            model='openai/gpt-5.4-mini', chat_mode='oficina_imagem',
            messages=[ChatMessage(role='user', content='Faz assim, crie uma foto sua em versão humana')],
            auto_memory=False,
            plugins={"memory": False, "web_search": False, "image_gen": True},
        )
        generated = {"ok": True, "mime": "image/png", "base64": "iVBORw0KGgo=", "model": "fake"}
        with (
            patch.object(chat_route.app_settings, 'AGENT_TOOLS_ENABLED', False),
            patch.object(chat_route.app_settings, 'IMAGE_GEN_ENABLED', True),
            patch.object(chat_route.gama, 'build_messages', new=AsyncMock(return_value=(
                [{"role": "user", "content": 'Faz assim, crie uma foto sua em versão humana'}], None, None, []
            ))),
            patch.object(chat_route.llm, 'stream_chat', new=fake_llm_stream),
            patch.object(chat_route, 'generate_image', new=AsyncMock(return_value=generated)) as generate,
            patch.object(chat_route, 'consume_daily_media_quota', return_value=None),
            patch.object(chat_route, 'schedule_summary_refresh', return_value=None),
        ):
            response = await chat_route.chat(request, user_id='test-create-image-user')
            events = []
            async for chunk in response.body_iterator:
                events.extend(json.loads(line) for line in chunk.splitlines() if line.strip())
        self.assertTrue(generate.await_count == 1, 'a API de imagem deveria ser chamada uma vez')
        self.assertIsNone(generate.await_args.kwargs.get('reference_images'))
        self.assertTrue(any((event.get('gama_meta') or {}).get('phase') == 'image_ready' for event in events), events)


if __name__ == "__main__":
    unittest.main()
