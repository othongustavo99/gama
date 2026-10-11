import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ["DATA_DIR"] = tempfile.mkdtemp()

from app.core import memory as mem  # noqa: E402


def texts(store):
    return [f["text"] for f in store.list_facts()]


class MemoryV2Test(unittest.TestCase):
    def setUp(self):
        self.uid = f"u{os.urandom(4).hex()}"
        self.s = mem.get_store(self.uid)

    # --- bugs da v1 -----------------------------------------------------
    def test_multi_valued_labels_are_kept(self):
        self.s.add_fact("Filho: João")
        self.s.add_fact("Filho: Pedro")
        self.s.add_fact("Projeto: Gama")
        self.s.add_fact("Projeto: hz_filmes")
        self.assertEqual(sorted(texts(self.s)), ["Filho: João", "Filho: Pedro", "Projeto: Gama", "Projeto: hz_filmes"])

    def test_single_valued_label_is_replaced(self):
        self.s.add_fact("Mora em: Campinas")
        self.s.add_fact("Mora em: Bragança Paulista")
        self.assertEqual(texts(self.s), ["Mora em: Bragança Paulista"])

    def test_preference_correction_wins(self):
        self.s.add_fact("Não gosta de: café")
        self.s.add_fact("Gosta de: café")
        self.assertEqual(texts(self.s), ["Gosta de: café"])
        self.s.add_fact("Não gosta de: café")
        self.assertEqual(texts(self.s), ["Não gosta de: café"])

    def test_corrupted_file_is_not_wiped(self):
        self.s.add_fact("Nome: Ana")
        self.s.add_fact("Mora em: Campinas")  # cria .bak com o estado anterior
        with open(self.s.path, "w") as f:
            f.write('{"facts": [{"id": "x", "text": "Nome: A')
        facts = texts(self.s)  # restaura do backup
        self.assertIn("Nome: Ana", facts)
        self.s.add_fact("Idade: 30 anos")
        self.assertIn("Nome: Ana", texts(self.s))
        self.assertIn("Idade: 30 anos", texts(self.s))

    def test_extraction_fixes(self):
        self.assertEqual(
            mem.try_extract_memories("prefiro que você sempre responda em tópicos curtos"),
            ["Comportamento: sempre responda em tópicos curtos"],
        )
        out = mem.try_extract_memories("gosto de café e não gosto de chá")
        self.assertIn("Gosta de: café", out)
        self.assertIn("Não gosta de: chá", out)
        self.assertEqual(mem.try_extract_memories("trabalho na minha tela de login hoje"), [])
        self.assertEqual(mem.try_extract_memories("qual é o meu nome?"), [])
        self.assertIn("Nome: Othon", mem.try_extract_memories("meu nome é othon"))

    # --- recursos novos -------------------------------------------------
    def test_sensitive_data_never_saved(self):
        for bad in [
            "senha: abc12345",
            "meu CPF é 123.456.789-09",
            "cartão 4111 1111 1111 1111",
            "chave sk-abcdefghijklmnopqrstuvwxyz123456",
        ]:
            with self.assertRaises(ValueError, msg=bad):
                self.s.add_fact(bad)
        self.assertEqual(mem.try_extract_memories("lembre que minha senha é hunter2xyz"), [])

    def test_forget(self):
        self.s.add_fact("Mora em: Campinas")
        self.s.add_fact("Nome: Ana")
        self.assertEqual(mem.try_forget("esqueça que moro em Campinas"), "moro em Campinas")
        removed = self.s.forget("moro em Campinas")
        self.assertEqual([f["text"] for f in removed], ["Mora em: Campinas"])
        self.assertEqual(texts(self.s), ["Nome: Ana"])
        self.assertIsNone(mem.try_forget("apague o arquivo main.dart"))
        self.assertIsNone(mem.try_forget("bom dia"))

    def test_behavior_block_and_core(self):
        self.s.add_fact("Comportamento: responder sempre em tópicos curtos")
        self.s.add_fact("Nome: Othon")
        self.s.add_fact("Gosta de: pizza")
        block = self.s.as_prompt_block("o que você sabe de mim?")
        self.assertIn("REGRAS DE COMPORTAMENTO DO USUÁRIO", block)
        self.assertIn("responder sempre em tópicos curtos", block)
        self.assertIn("MEMÓRIA PERSISTENTE DO USUÁRIO", block)
        self.assertIn("Nome: Othon", block)
        self.assertIn("pizza", block)
        self.assertNotIn("Comportamento:", block)

    def test_relevance_selects_subset_for_big_memory(self):
        for i in range(60):
            self.s.add_fact(f"Gosta de: item{i} colecionável{i}")
        self.s.add_fact("Projeto: aplicativo de receitas veganas")
        rel, ids = self.s.relevant_block("quero ideias para o aplicativo de receitas")
        self.assertIn("receitas veganas", rel)
        self.assertLessEqual(len(ids), self.s.RELEVANT_K)
        self.assertLess(rel.count("\n"), 20)

    def test_eviction_keeps_identity_and_pinned(self):
        self.s.MAX_FACTS = 10
        self.s.add_fact("Nome: Ana")
        self.s.add_fact("Gosta de: algo fixado", pinned=True)
        for i in range(30):
            self.s.add_fact(f"Gosta de: coisa{i} bem{i}")
        t = texts(self.s)
        self.assertEqual(len(t), 10)
        self.assertIn("Nome: Ana", t)
        self.assertIn("Gosta de: algo fixado", t)

    def test_v1_files_still_load(self):
        import json
        with open(self.s.path, "w", encoding="utf-8") as f:
            json.dump({"facts": [{"id": "a", "text": "Nome: Zé", "created_at": "2025-01-01T00:00:00+00:00", "source": "user"}]}, f)
        facts = self.s.list_facts()
        self.assertEqual(facts[0]["category"], "identity")
        self.assertEqual(facts[0]["importance"], 5)

    def test_update_and_mark_used(self):
        f = self.s.add_fact("Gosta de: jazz")
        up = self.s.update_fact(f["id"], pinned=True, importance=5)
        self.assertTrue(up["pinned"])
        self.s.mark_used([f["id"]])
        self.assertEqual(self.s.list_facts()[0]["uses"], 1)
        self.s.mark_used([f["id"]])  # dentro de 1h: não incrementa de novo
        self.assertEqual(self.s.list_facts()[0]["uses"], 1)

    def test_migrate(self):
        a, b = mem.get_store(self.uid + "a"), mem.get_store(self.uid + "b")
        a.add_fact("Nome: Ana"); b.add_fact("Idade: 30 anos")
        r = mem.migrate_memory(self.uid + "a", self.uid + "b")
        self.assertEqual(r["merged"], 1)
        self.assertEqual(sorted(texts(b)), ["Idade: 30 anos", "Nome: Ana"])

    def test_path_traversal_user_id(self):
        s = mem.get_store("../../etc/passwd")
        self.assertTrue(str(s.path).startswith(os.environ["DATA_DIR"]))


if __name__ == "__main__":
    unittest.main()
