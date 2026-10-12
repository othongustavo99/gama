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


if __name__ == "__main__":
    unittest.main()
