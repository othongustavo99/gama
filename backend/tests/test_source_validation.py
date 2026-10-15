"""Validação segura de sintaxe em arquivos entregues em ZIP."""
from __future__ import annotations

import io
import os
import sys
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app.core.document_builder.validator import validate_source_archive  # noqa: E402
from app.core.code_analyzer.index_store import new_project_id, save_meta
from app.core.code_analyzer.pipeline import build_coverage_report


def archive(files: dict[str, str]) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, content in files.items():
            zf.writestr(name, content)
    return out.getvalue()


class SourceValidationTests(unittest.TestCase):
    def test_reports_valid_python_json_and_xml(self):
        result = validate_source_archive(archive({
            "src/main.py": "def main():\n    return 1\n",
            "config.json": '{"ok": true}',
            "resources/app.xml": "<app><name>Gamma</name></app>",
        }))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["checked_count"], 3)
        self.assertEqual(result["issue_count"], 0)

    def test_reports_syntax_error_without_executing_code(self):
        result = validate_source_archive(archive({"broken.py": "def main(:\n  import os; os.remove('important')\n"}))
        self.assertFalse(result["ok"])
        self.assertEqual(result["issues"][0]["path"], "broken.py")
        self.assertIsNotNone(result["issues"][0]["line"])

    def test_unsupported_languages_are_not_claimed_as_validated(self):
        result = validate_source_archive(archive({"lib/main.dart": "void main() {}\n", "app.js": "let x = ;"}))
        self.assertTrue(result["ok"])
        self.assertEqual(result["checked_count"], 0)
        self.assertIn("não substitui", result["note"])

    def test_coverage_report_explicitly_marks_selective_analysis(self):
        pid = new_project_id()
        save_meta(pid, {
            "name": "repo", "user_id": "alpha", "source": {"type": "zip"},
            "map": {"file_count": 2, "files": [{"path": "main.py"}, {"path": "other.py"}]},
        })
        context = (
            "### main.py — linhas 1-3\n```\nprint(1)\n```\n"
            "[Evidências incluídas neste turno — cite somente estas referências]\n"
            "- main.py: linhas 1-3\n"
        )
        report = build_coverage_report(pid, context, level="targeted")
        self.assertEqual(report["status"], "parcial")
        self.assertEqual(report["included_paths"], ["main.py"])
        self.assertEqual(report["omitted_paths_sample"], ["other.py"])
        self.assertFalse(report["full_project_review"])


if __name__ == "__main__":
    unittest.main()
