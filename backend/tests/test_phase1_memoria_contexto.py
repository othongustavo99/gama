"""Regressões: captação, esquecimento seguro e modo Conversar da Fase 1."""
import os
import tempfile
import unittest
from unittest.mock import patch

from app.core import memory as mem
from app.core.context import normalize_messages
from app.core.context_budget import budget_messages_with_report
from app.core.talk_skill import build_talk_layer
from app.models import ChatRequest


class Phase1MemoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.original_dir = os.environ.get('DATA_DIR')
        os.environ['DATA_DIR'] = self.tmp.name
        self.store = mem.get_store('phase1_test')

    def tearDown(self):
        if self.original_dir is None:
            os.environ.pop('DATA_DIR', None)
        else:
            os.environ['DATA_DIR'] = self.original_dir
        self.tmp.cleanup()

    def test_personal_facts_and_no_profession_hallucination(self):
        cases = {
            'Trabalho com Flutter': ['Stack: Flutter'],
            'eu trabalho de manhã e estudo à noite': [],
            'Sou de São Paulo mesmo': ['Natural de: São Paulo'],
            'pode me chamar de Gus': ['Apelido: Gus'],
            'Estou desenvolvendo um assistente chamado Gama em Flutter': ['Projeto: Gama'],
            'Uso Flutter e Dart no dia a dia': ['Stack: Flutter e Dart'],
        }
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(mem.try_extract_memories(source), expected)

    def test_apelido_does_not_replace_name(self):
        for text in ('meu nome é Othon Gustavo', 'pode me chamar de Gus'):
            for fact in mem.try_extract_memories(text):
                self.store.add_fact(fact)
        texts = [item['text'] for item in self.store.list_facts()]
        self.assertIn('Nome: Othon Gustavo', texts)
        self.assertIn('Apelido: Gus', texts)

    def test_explicit_phrases_supported_and_forget_is_conservative(self):
        self.assertEqual(mem.try_extract_memories('guarda isso na memória: prefiro respostas curtas'), ['Prefere: respostas curtas'])
        self.assertTrue(mem.fact_supported_by_user('Stack: Flutter e Dart', 'Uso Flutter e Dart no dia a dia'))
        self.assertTrue(mem.fact_supported_by_user('Projeto: Gama', 'Estou desenvolvendo um assistente chamado Gama em Flutter'))
        self.assertIsNone(mem.try_forget('remova a dependência do projeto'))
        self.assertIsNone(mem.try_forget('esqueça isso'))
        self.store.add_fact('Projeto: Gama')
        self.store.add_fact('Projeto: hz_filmes')
        self.assertEqual(self.store.forget('projeto'), [])
        removed = self.store.forget(mem.try_forget('esqueça meu projeto hz_filmes'))
        self.assertEqual([f['text'] for f in removed], ['Projeto: hz_filmes'])
        self.assertEqual([f['text'] for f in self.store.list_facts()], ['Projeto: Gama'])

    def test_ambiguous_forget_does_not_delete(self):
        self.store.add_fact('Projeto: hz_filmes módulo de catálogo')
        self.store.add_fact('Projeto: hz_filmes módulo de pagamentos')
        self.assertEqual(self.store.forget('hz_filmes'), [])
        self.assertEqual(len(self.store.list_facts()), 2)

    def test_unrelated_memories_not_injected_as_baseline(self):
        for interest in ('jazz', 'xadrez', 'marcenaria', 'jardinagem', 'astronomia', 'surfe', 'tricô', 'arqueologia', 'culinária', 'fotografia', 'pintura', 'ciclismo'):
            self.store.add_fact(f'Gosta de: {interest}')
        self.assertEqual(self.store.select_relevant('qual a temperatura na lua'), [])

    def test_chat_request_structured_image_settings(self):
        r = ChatRequest(model='m', chat_mode='oficina_imagem', messages=[{'role': 'user', 'content': 'desenhe algo'}],
                        image_aspect_ratio='16:9', image_style='Noturno')
        self.assertEqual(r.image_aspect_ratio, '16:9')
        self.assertEqual(r.image_style, 'Noturno')

    def test_context_default_latest_user_can_be_large(self):
        from app.core.context_budget import MAX_LAST_USER_CHARS, CONTEXT_CURRENT_USER_CHARS
        # Default ou valor explícito no Railway: atualizar a env para 100k.
        if 'GAMA_CONTEXT_MAX_CURRENT_USER_CHARS' not in os.environ:
            self.assertEqual(CONTEXT_CURRENT_USER_CHARS, MAX_LAST_USER_CHARS)
        user_msg = 'u' * 50_000
        budgeted, _ = budget_messages_with_report([{'role':'system','content':'base'}, {'role':'user','content': user_msg}], max_total_chars=200_000)
        self.assertEqual(budgeted[-1]['content'], user_msg)

    def test_talk_layer_can_prioritize_conversational(self):
        mode, layer = build_talk_layer('Hoje acordei cansado e pensei em mudar de área', force_mode='conversational')
        self.assertEqual(mode, 'conversational')
        self.assertTrue(layer)

class Phase1IntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_regex_memory_capture_on_first_turn_not_only_fifth(self):
        from app.core.gama import GamaCore
        with tempfile.TemporaryDirectory() as folder:
            with patch.dict(os.environ, {'DATA_DIR': folder}):
                messages, saved, *_ = await GamaCore().build_messages(
                    [{'role': 'user', 'content': 'pode me chamar de Gus'}],
                    model='openai/gpt-5.4-mini', ollama_client=None,
                    user_id='first-turn', chat_mode='conversar',
                    enable_web_search=False, enable_code_analyzer=False,
                    enable_memory=True, auto_memory=True,
                )
                self.assertEqual(saved, 'Apelido: Gus')
                self.assertIn('Apelido: Gus', '\n'.join(str(m.get('content')) for m in messages))
                self.assertIn('Apelido: Gus', [f['text'] for f in mem.get_store('first-turn').list_facts()])

    async def test_work_mode_preserves_ordinary_conversation(self):
        from app.core.gama import GamaCore
        with tempfile.TemporaryDirectory() as folder:
            with patch.dict(os.environ, {'DATA_DIR': folder}):
                for mode in ('conversar', 'programar'):
                    with self.subTest(mode=mode):
                        messages, *_ = await GamaCore().build_messages(
                            [{'role': 'user', 'content': 'Hoje acordei meio cansado; devo mudar de área?'}],
                            model='openai/gpt-5.4-mini', ollama_client=None,
                            user_id='modes', chat_mode=mode, auto_memory=False,
                            enable_memory=False, enable_web_search=False,
                            enable_code_analyzer=False,
                        )
                        self.assertTrue(messages)


if __name__ == '__main__':
    unittest.main()
