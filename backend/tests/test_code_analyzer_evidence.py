from __future__ import annotations

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
os.environ.setdefault("DATA_DIR", tempfile.mkdtemp())

import _httpx_stub  # noqa: F401,E402
from app.core.code_analyzer.context_builder import build_context  # noqa: E402


class CodeEvidenceTests(unittest.TestCase):
    def test_large_file_is_retrieved_as_query_relevant_line_chunks(self):
        lines = [f"line_{number}: unrelated_value = {number}\n" for number in range(1, 450)]
        lines[320] = "line_321: critical_authentication_marker = True\n"
        source = "".join(lines)
        context = build_context(
            {"file_count": 1, "files": [{"path": "src/auth.py"}], "frameworks": []},
            [{"path": "src/auth.py", "score": 4.0, "text": source}],
            "critical authentication marker",
            max_tokens=1000,
        )

        self.assertIn("src/auth.py — linhas", context)
        self.assertIn("critical_authentication_marker", context)
        self.assertIn("[Evidências incluídas neste turno", context)
        self.assertIn("src/auth.py: linhas", context)
        self.assertIn("linhas omitidas", context)
        self.assertNotIn("line_1:", context)

    def test_pdf_evidence_uses_page_number_without_inventing_source_lines(self):
        context = build_context(
            {"file_count": 1, "files": [{"path": "page_7"}], "frameworks": ["PDF"]},
            [{"path": "page_7", "page": 7, "score": 2.0, "text": "recognized text"}],
            "recognized text",
        )

        self.assertIn("page_7 — página 7", context)
        self.assertIn("PDF página 7 (page_7)", context)
        self.assertNotIn("page_7: linhas", context)

    def test_no_loaded_code_disclaims_evidence(self):
        context = build_context(
            {"file_count": 0, "files": [], "frameworks": []},
            [],
            "analyze the project",
        )
        self.assertIn("Nenhum trecho de arquivo foi incluído", context)


    def test_short_requested_files_are_not_starved_by_a_long_first_file(self):
        main = "// huge main\n" + "const huge = 12345;\n" * 7000
        providers = "// PROVIDER_BEGIN\n" + "class ProductProvider {}\n" * 80 + "// PROVIDER_END\n"
        repo = "// REPO_BEGIN\n" + "class ProductRepository {}\n" * 70 + "// REPO_END\n"
        ranked = [
            {"path": "lib/main.dart", "text": main, "forced": True, "score": 999.0},
            {"path": "lib/providers/product_providers.dart", "text": providers, "forced": True, "score": 999.0},
            {"path": "lib/data/repositories/product_repository.dart", "text": repo, "forced": True, "score": 999.0},
        ]
        context = build_context(
            {"file_count": 3, "files": [{"path": r["path"]} for r in ranked], "frameworks": ["Flutter"]},
            ranked, "devolva esses arquivos completos corrigidos em zip", max_tokens=1000,
        )
        self.assertIn("PROVIDER_BEGIN", context)
        self.assertIn("PROVIDER_END", context)
        self.assertIn("REPO_BEGIN", context)
        self.assertIn("REPO_END", context)
        self.assertIn("linhas omitidas", context)  # main.dart ainda precisa de trechos

    def test_multiple_requested_large_files_stay_inside_context_budget(self):
        from app.core.code_analyzer.context_builder import _budget_chars

        files = [
            {
                "path": f"src/module_{index}.py",
                "score": 999.0,
                "important": True,
                "forced": True,
                "text": (f"# module {index}\n" + ("unrelated_line = 123\n" * 3500)),
            }
            for index in range(3)
        ]
        context = build_context(
            {
                "file_count": 3,
                "files": [{"path": item["path"]} for item in files],
                "frameworks": ["Python"],
            },
            files,
            "me envie os códigos completos para substituir",
            max_tokens=1000,
        )

        # A revisão de vários arquivos completos não deve ultrapassar o teto
        # global de contexto, mesmo quando todos foram marcados como obrigatórios.
        self.assertLessEqual(len(context), _budget_chars(18500) + 500)
        self.assertIn("trechos enviados", context)
        self.assertNotIn(r"\n###", context)

if __name__ == "__main__":
    unittest.main()
