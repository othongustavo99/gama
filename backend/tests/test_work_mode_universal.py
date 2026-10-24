"""Trabalhar = modelo técnico forte, não obrigação de falar de projetos."""

import asyncio
import os
import tempfile
import unittest
from unittest.mock import patch

from app.core.gama import GamaCore
from app.core.prompts import build_system_prompt
from app.core.conversation_session import load_session, save_session, session_key
from app.core.work_intent import detect_work_intent


class WorkIntentTests(unittest.TestCase):
    def test_conversa_comum_nao_vira_programacao(self):
        for text in (
            "Tudo bem?", "Qual a sua opinião sobre a Lua?",
            "Como nasceu a civilização egípcia?",
            "Me ajude a analisar minhas opções de carreira",
            "Quero falar do meu projeto de vida",
            "Me dê ideias de um projeto social",
            "O que você acha desta música?",
        ):
            with self.subTest(text=text):
                intent = detect_work_intent(text, has_active_project=True)
                self.assertFalse(intent.code_task)
                self.assertFalse(intent.project_context)

    def test_tarefas_tecnicas_continuam_ativas(self):
        for text in (
            "Corrija o bug no Flutter", "Explique o código Python abaixo",
            "Refatore main.dart", "Analise meu projeto de software",
            "Quero criar uma API com FastAPI", "Veja esse endpoint",
        ):
            with self.subTest(text=text):
                self.assertTrue(detect_work_intent(text, has_active_project=True).code_task)

    def test_anexos_e_referencia_ativam_projeto(self):
        for text in (
            "[project_id:abcDEF012345] revise", "https://github.com/x/y",
            "Como ficou o main.dart?", "Corrija esse projeto",
        ):
            with self.subTest(text=text):
                self.assertTrue(detect_work_intent(text, has_active_project=True).project_context)

    def test_confirmacao_preserva_intencao_do_turno_anterior(self):
        code_history = [
            {"role": "user", "content": "Corrija esse projeto Flutter"},
            {"role": "assistant", "content": "Quer que eu corrija o ZIP?"},
            {"role": "user", "content": "sim"},
        ]
        self.assertTrue(detect_work_intent("sim", messages=code_history, has_active_project=True).project_context)
        casual_history = [
            {"role": "user", "content": "Corrija esse projeto Flutter"},
            {"role": "assistant", "content": "Concluído"},
            {"role": "user", "content": "Agora me explique por que Saturno tem anéis"},
            {"role": "assistant", "content": "Por causa de partículas"},
            {"role": "user", "content": "continua"},
        ]
        intent = detect_work_intent("continua", messages=casual_history, has_active_project=True)
        self.assertFalse(intent.code_task)
        self.assertFalse(intent.project_context)

    def test_trabalhar_nao_impoe_codigo_em_assuntos_gerais(self):
        prompt = build_system_prompt(work_mode=True, programming_mode=False)
        self.assertIn("ASSISTÊNCIA UNIVERSAL", prompt)
        self.assertNotIn("FOCO EM PROGRAMAÇÃO", prompt)
        code_prompt = build_system_prompt(work_mode=True, programming_mode=True)
        self.assertIn("FOCO EM PROGRAMAÇÃO", code_prompt)
        self.assertIn("ASSISTÊNCIA UNIVERSAL", code_prompt)


class WorkModeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"DATA_DIR": self.tmp.name})
        self.env.start()
        self.core = GamaCore()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def _build(self, text, *, mode="trabalhar", cid="t1", history=None):
        history = history or [{"role": "user", "content": text}]
        return asyncio.run(self.core.build_messages(
            history, model="z-ai/glm-5.3-flash", ollama_client=None,
            auto_memory=False, enable_web_search=False, enable_memory=False,
            user_id="u_work_mode", conversation_id=cid, chat_mode=mode,
        ))[0]

    def test_casual_works_even_after_active_project(self):
        key = session_key("u_work_mode", "t1")
        state = load_session(key)
        state["active_project_id"] = "abcdef123456"
        state["actions"] = ["Projeto ativo: abcdef123456"]
        save_session(state)
        with patch.object(self.core, "_code_analyzer_block", side_effect=AssertionError("unnecessary analyzer")):
            prepared = self._build("Vamos conversar sobre a história de Roma")
        system = prepared[0]["content"]
        self.assertIn("ASSISTÊNCIA UNIVERSAL", system)
        self.assertNotIn("FOCO EM PROGRAMAÇÃO", system)
        self.assertNotIn("Projeto ativo: abcdef123456", " ".join(m["content"] for m in prepared))
        # O projeto não foi apagado da sessão.
        self.assertEqual(load_session(key)["active_project_id"], "abcdef123456")

    def test_technical_task_keeps_programming_rules(self):
        prepared = self._build("Escreva um widget Flutter que mostre a hora")
        self.assertIn("FOCO EM PROGRAMAÇÃO", prepared[0]["content"])

    def test_project_request_loads_analyzer(self):
        key = session_key("u_work_mode", "t1")
        state = load_session(key)
        state["active_project_id"] = "abcdef123456"
        save_session(state)
        with patch.object(self.core, "_code_analyzer_block", return_value="[Code Analyzer] main.dart") as analyzer:
            prepared = self._build("Corrija esse projeto Flutter")
        analyzer.assert_called_once()
        self.assertTrue(any("[Code Analyzer]" in m["content"] for m in prepared))
        self.assertIn("FOCO EM PROGRAMAÇÃO", prepared[0]["content"])

    def test_conversar_does_not_inherit_work_policies(self):
        prepared = self._build("Tudo bem?", mode="conversar")
        self.assertNotIn("ASSISTÊNCIA UNIVERSAL", prepared[0]["content"])
        self.assertNotIn("FOCO EM PROGRAMAÇÃO", prepared[0]["content"])


if __name__ == "__main__":
    unittest.main()
