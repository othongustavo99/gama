"""Regressões de proteção de segredos e de mensagens de validação."""
from __future__ import annotations

import io
import os
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.core.code_analyzer.cleaner import is_sensitive_file, should_skip_file  # noqa: E402
from app.core.code_analyzer.extractor import safe_extract  # noqa: E402
from app.core.document_builder.validator import validate_source_archive  # noqa: E402
from app.core.document_builder.zip_builder import (  # noqa: E402
    build_zip_from_mapping,
    build_zip_with_report,
)
from app.core.project_analyzer.cleaner import should_skip_file as project_should_skip_file  # noqa: E402
from app.core.project_analyzer.extractor import (  # noqa: E402
    MAX_ZIP_BYTES as PROJECT_MAX_ZIP_BYTES,
    safe_extract as project_safe_extract,
)


def make_zip(entries: dict[str, str]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, content in entries.items():
            archive.writestr(path, content)
    return buffer.getvalue()


class SensitiveFileTests(unittest.TestCase):
    def test_sensitive_names_are_recognized_but_templates_are_kept(self):
        for path in (
            ".env", ".env.production", "secrets.json", "keys/id_rsa", "tls/private.pem",
            ".aws/credentials", ".kube/config", "secrets/config.json",
            ".config/gcloud/application_default_credentials.json",
        ):
            with self.subTest(path=path):
                self.assertTrue(is_sensitive_file(path))
                self.assertTrue(should_skip_file(Path(path)))
        for path in (".env.example", ".env.sample", "service-account.example.json", "lib/main.dart"):
            with self.subTest(path=path):
                self.assertFalse(is_sensitive_file(path))

    def test_project_analyzer_cleaner_uses_shared_sensitive_path_rules(self):
        self.assertTrue(project_should_skip_file(Path(".aws/credentials")))
        self.assertTrue(project_should_skip_file(Path(".env")))
        self.assertFalse(project_should_skip_file(Path(".env.example")))

    def test_ingest_never_extracts_env_or_private_keys(self):
        data = make_zip({
            "project/lib/main.py": "print('ok')",
            "project/.env": "OPENROUTER_API_KEY=secret",
            "project/.env.example": "OPENROUTER_API_KEY=change-me",
            "project/keys/id_rsa": "PRIVATE KEY",
        })
        tmp = Path(tempfile.mkdtemp())
        try:
            count = safe_extract(data, tmp)
            self.assertEqual(count, 2)
            self.assertTrue((tmp / "project/lib/main.py").exists())
            self.assertTrue((tmp / "project/.env.example").exists())
            self.assertFalse((tmp / "project/.env").exists())
            self.assertFalse((tmp / "project/keys/id_rsa").exists())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_project_analyzer_also_filters_secrets_and_accepts_200_mib_limit(self):
        data = make_zip({
            "project/lib/main.dart": "void main() {}",
            "project/.env": "OPENROUTER_API_KEY=secret",
            "project/.env.example": "OPENROUTER_API_KEY=change-me",
        })
        tmp = Path(tempfile.mkdtemp())
        try:
            count = project_safe_extract(data, tmp)
            self.assertEqual(count, 2)
            self.assertFalse((tmp / "project/.env").exists())
            self.assertTrue((tmp / "project/.env.example").exists())
            self.assertEqual(PROJECT_MAX_ZIP_BYTES, 200 * 1024 * 1024)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_generated_zip_omits_secrets_even_when_junk_is_enabled(self):
        tmp = Path(tempfile.mkdtemp())
        root = tmp / "project"
        root.mkdir()
        try:
            (root / "main.py").write_text("print('ok')", encoding="utf-8")
            (root / ".env").write_text("OPENROUTER_API_KEY=secret", encoding="utf-8")
            (root / ".env.example").write_text("OPENROUTER_API_KEY=change-me", encoding="utf-8")
            data, report = build_zip_with_report(root, include_junk=True)
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                names = set(archive.namelist())
                self.assertIn("main.py", names)
                self.assertIn(".env.example", names)
                self.assertNotIn(".env", names)
            self.assertTrue(any("sensível" in item["reason"] for item in report["skipped"]))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_unsupported_source_language_is_marked_partial_not_passed(self):
        data = make_zip({"lib/main.dart": "void main() {}", "src/app.js": "const ok = true;"})
        result = validate_source_archive(data)
        self.assertTrue(result["ok"])  # compatibilidade: sem problemas conhecidos
        self.assertEqual(result["status"], "not_checked")
        self.assertFalse(result["syntax_check_complete"])
        self.assertEqual(result["unverified_count"], 2)

    def test_generated_mapping_zip_rejects_sensitive_file_names(self):
        with self.assertRaisesRegex(ValueError, "Arquivo sensível"):
            build_zip_from_mapping({"main.dart": "void main() {}", ".env": "TOKEN=secret"})
        # Model-generated example templates remain allowed.
        data = build_zip_from_mapping({".env.example": "TOKEN=replace-me"})
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            self.assertIn(".env.example", archive.namelist())

    def test_validator_flags_secrets_in_any_archive(self):
        result = validate_source_archive(make_zip({".env": "TOKEN=secret", "main.py": "print(1)"}))
        self.assertFalse(result["ok"])
        self.assertTrue(any(issue["validator"] == "sensitive-path" for issue in result["issues"]))


if __name__ == "__main__":
    unittest.main()
