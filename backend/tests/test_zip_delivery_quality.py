"""Regression checks for accurate and complete ZIP downloads."""
from __future__ import annotations

import hashlib
import io
import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from app.core.document_builder.pipeline import build_zip_from_files
from app.core.document_builder.store import load_artifact
from app.core.file_bundle import _complete_file_response
from app.routes.chat import (
    _filter_real_files,
    _parse_gama_files,
    _public_artifact_metadata,
    _require_real_files,
    _safe_artifacts_json,
    _zip_bundle_digest,
)


class ZipDeliveryQualityTests(unittest.TestCase):
    def test_model_bundle_only_contains_fenced_file_contents(self):
        response = '''[[GAMA_FILES]]
path: lib/main.dart
````dart
import 'package:flutter/material.dart';

void main() {
  runApp(const SizedBox());
}
````
Esta explicação NÃO faz parte do arquivo.
path: pubspec.yaml
````yaml
name: exemplo

dependencies:
  flutter:
    sdk: flutter
````
[[/GAMA_FILES]]'''
        files = _parse_gama_files(response)
        self.assertEqual(set(files), {"lib/main.dart", "pubspec.yaml"})
        self.assertNotIn('explicação', files['lib/main.dart'])
        self.assertIn("\n\nvoid main()", files['lib/main.dart'])
        self.assertTrue(files['pubspec.yaml'].endswith('\n'))

    def test_rejects_partial_and_unfenced_files(self):
        incomplete = '[[GAMA_FILES]]\npath: lib/main.dart\n````dart\nvoid main() {}'
        self.assertEqual(_parse_gama_files(incomplete), {})
        no_fence = ('[[GAMA_FILES]]\npath: main.dart\nvoid main() {}\n'
                    '[[/GAMA_FILES]]')
        with self.assertRaises(ValueError):
            _parse_gama_files(no_fence)
        multiple_one_truncated = '''[[GAMA_FILES]]
path: one.py
````
print(1)
````
path: two.py
````
print(2)
[[/GAMA_FILES]]'''
        with self.assertRaises(ValueError):
            _parse_gama_files(multiple_one_truncated)

    def test_placeholder_is_not_packaged(self):
        files = {"main.dart": "# arquivo não disponível no contexto\n"}
        self.assertEqual(_filter_real_files(files), {})
        with self.assertRaises(ValueError):
            _require_real_files({"ok.py": "print(1)", **files})
        self.assertFalse(_complete_file_response(
            '[[GAMA_FILES]]\npath: main.dart\n````\n'
            '# arquivo não disponível no contexto\n````\n[[/GAMA_FILES]]', 'main.dart'))

    def test_same_file_contents_have_same_digest_regardless_of_order(self):
        a = {"lib/a.dart": "void a() {}", "lib/b.dart": "void b() {}"}
        b = dict(reversed(list(a.items())))
        self.assertEqual(_zip_bundle_digest(a), _zip_bundle_digest(b))
        self.assertNotEqual(_zip_bundle_digest(a), _zip_bundle_digest({"lib/a.dart": "void c() {}"}))

    def test_public_artifact_metadata_does_not_fake_integrity_failure(self):
        full = {
            "artifact_id": "a123", "filename": "example.zip", "kind": "zip",
            "sha256": "f" * 64, "size": 154,
            "validation": {"ok": True, "entry_count": 2, "sample": ["a.dart"]},
            "source_validation": {"status": "not_checked", "unverified_count": 1,
                                  "checked_count": 0, "note": "Dart SDK indisponível"},
            "generated_files": [{"preview": "ABC" * 50000}],
            "path": "/tmp/private-location",
        }
        safe = _public_artifact_metadata(full)
        self.assertEqual(safe['validation']['ok'], True)
        self.assertEqual(safe['source_validation']['status'], 'not_checked')
        self.assertNotIn('generated_files', safe)
        self.assertNotIn('path', safe)
        synced = json.loads(_safe_artifacts_json([full]))[0]
        self.assertEqual(synced['sha256'], 'f' * 64)
        self.assertTrue(synced['validation']['ok'])

    def test_generated_zip_matches_original_bytes_and_sha256(self):
        with tempfile.TemporaryDirectory() as data:
            with patch.dict(os.environ, {"DATA_DIR": data}):
                files = {
                    "lib/main.dart": "void main() { print('Olá'); }\n",
                    "pubspec.yaml": "name: minha_gamma\n",
                }
                created = build_zip_from_files(files, filename="meu_exemplo.zip", user_id="owner")
                artifact = load_artifact(created['artifact_id'], user_id="owner", include_bytes=True)
                self.assertIsNotNone(artifact)
                self.assertTrue(created['validation']['ok'])
                self.assertEqual(created['included_files'], 2)
                self.assertEqual(created['sha256'], hashlib.sha256(artifact['bytes']).hexdigest())
                with zipfile.ZipFile(io.BytesIO(artifact['bytes'])) as zf:
                    self.assertIsNone(zf.testzip())
                    for path, content in files.items():
                        self.assertEqual(zf.read(path), content.encode('utf-8'))


if __name__ == '__main__':
    unittest.main()
