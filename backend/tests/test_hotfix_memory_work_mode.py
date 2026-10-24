"""Regressão: apelidos e regras persistentes não dependem do tema ou modo."""
import os
import tempfile
import unittest
from unittest.mock import patch

from app.core.memory import get_store
from app.core.gama import GamaCore


class MemoryAcrossModesTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"DATA_DIR": self.temp.name})
        self.env.start()
        self.store = get_store("account-one")
        self.store.add_fact("Nome: Pessoa Teste")
        # Simula um apelido antigo não rotulado e outro armazenado na taxonomia nova.
        self.store.add_fact("Prefere: me chame de Capitã", category="preference")
        self.store.add_fact("Comportamento: responda de forma descontraída", category="behavior")
        self.store.add_fact("Prefere: respostas detalhadas em assuntos técnicos", category="preference")
        for i in range(30):
            self.store.add_fact(f"Gosta de: assunto-temporario-{i} detalhe-{i}")

    async def asyncTearDown(self):
        self.env.stop()
        self.temp.cleanup()

    async def _build(self, mode: str, enable_memory=True):
        return await GamaCore().build_messages(
            [{"role":"user", "content":"Você está bem hoje?"}],
            model="z-ai/glm-5.3-flash" if mode == "programar" else "openai/gpt-5.4-mini",
            ollama_client=None,
            user_id="account-one",
            chat_mode=mode,
            enable_memory=enable_memory,
            auto_memory=False,
            enable_web_search=False,
            enable_code_analyzer=False,
        )

    async def test_work_and_conversation_keep_addressing(self):
        for mode in ("programar", "conversar"):
            with self.subTest(mode=mode):
                prepared, *_ = await self._build(mode)
                combined = '\n'.join(m['content'] for m in prepared if m['role'] == 'system')
                self.assertIn('me chame de Capitã', combined)
                self.assertIn('responda de forma descontraída', combined)
                self.assertIn('Prefere: respostas detalhadas', combined)
                self.assertIn('Nome: Pessoa Teste', combined)

    async def test_disabled_memory_does_not_read_facts(self):
        prepared, *_ = await self._build('programar', enable_memory=False)
        combined = '\n'.join(m['content'] for m in prepared if m['role'] == 'system')
        self.assertNotIn('me chame de Capitã', combined)
        self.assertNotIn('Nome: Pessoa Teste', combined)

    async def test_does_not_inject_unrelated_preferences(self):
        core = self.store.core_block()
        self.assertNotIn('assunto-temporario', core)
        self.assertIn('Capitã', core)
        self.assertIn('REGRAS DE COMPORTAMENTO DO USUÁRIO', core)
        self.assertEqual(core.count('Prefere: respostas detalhadas'), 1)

    async def test_new_alias_is_identity_and_replaces_previous(self):
        s = get_store('second-account')
        s.add_fact('Apelido: Estrela')
        s.add_fact('Apelido: Céu')
        core = s.core_block()
        self.assertIn('Apelido: Céu', core)
        self.assertNotIn('Apelido: Estrela', core)


if __name__ == '__main__':
    unittest.main()
