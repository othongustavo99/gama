"""Fase 5: auditoria de patches e prevenção de entregas parciais/sintaxe inválida."""
from __future__ import annotations

import asyncio
import io
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from tests import _httpx_stub  # noqa: F401
from app.core.document_builder import pipeline, store
from app.core.document_builder.change_report import compare_snapshots, snapshot_tree
from app.core.document_builder.zip_builder import build_zip_from_mapping
from app.core.code_analyzer.index_store import load_meta, new_project_id, save_meta, workspace
from app.routes.project import project_review_plan
from fastapi import HTTPException


def zip_input(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        for path, content in files.items():
            archive.writestr(path, content)
    return output.getvalue()


class Phase5WorkshopTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old = os.environ.get('DATA_DIR')
        os.environ['DATA_DIR'] = self.temp.name

    def tearDown(self):
        if self.old is None:
            os.environ.pop('DATA_DIR', None)
        else:
            os.environ['DATA_DIR'] = self.old
        self.temp.cleanup()

    def test_failed_edit_does_not_publish_misleading_zip(self):
        source = zip_input({'app/a.py': 'print(1)\n'})
        with self.assertRaisesRegex(ValueError, 'Nenhum ZIP foi publicado'):
            pipeline.apply_edits_and_zip(
                zip_bytes=source,
                edits=[{'path': 'app/a.py', 'action': 'replace', 'old': 'not_there', 'new': 'x'}],
            )
        self.assertEqual(store.list_recent(user_id='default'), [])

    def test_successful_patch_reports_exact_digests_and_replacement(self):
        source = zip_input({'project/src/main.py': 'VALUE = 1\n', 'project/README.md': 'readme\n'})
        result = pipeline.apply_edits_and_zip(
            zip_bytes=source,
            edits=[{'path': 'src/main.py', 'action': 'replace', 'old': 'VALUE = 1', 'new': 'VALUE = 2'}],
            extra_files={'src/new.py': 'VALUE = 3\n'},
        )
        self.assertEqual(result['change_report']['changed_count'], 2)
        self.assertEqual(result['change_report']['counts']['added'], 1)
        self.assertEqual(result['change_report']['counts']['modified'], 1)
        entry = next(item for item in result['change_report']['changes'] if item['path'] == 'src/main.py')
        self.assertEqual(len(entry['after']['sha256']), 64)
        self.assertNotEqual(entry['before']['sha256'], entry['after']['sha256'])
        self.assertIn('-VALUE = 1', result['change_report']['diff_previews']['src/main.py'])
        self.assertTrue(result['source_validation']['ok'])
        data = store.load_artifact(result['artifact_id'], include_bytes=True)['bytes']
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            self.assertEqual(zf.read('src/main.py'), b'VALUE = 2\n')
            self.assertEqual(zf.read('src/new.py'), b'VALUE = 3\n')
        self.assertIn('change_report', store.load_artifact(result['artifact_id']))

    def test_invalid_updated_python_cannot_be_published(self):
        source = zip_input({'a.py': 'print(1)\n'})
        with self.assertRaisesRegex(ValueError, 'problemas sintáticos'):
            pipeline.apply_edits_and_zip(zip_bytes=source, edits=[
                {'path': 'a.py', 'action': 'write', 'content': 'def bad(:\n'}])
        self.assertEqual(store.list_recent(user_id='default'), [])

    def test_sensitive_or_skipped_file_changes_cannot_be_silent(self):
        source = zip_input({'a.py': 'print(1)\n'})
        for filename in ['.env', '.git/config', 'build/generated.py', 'secret/id_rsa']:
            with self.subTest(filename=filename):
                with self.assertRaises(ValueError):
                    pipeline.apply_edits_and_zip(
                        zip_bytes=source, edits=[{'path': filename, 'action': 'write', 'content': 'private'}]
                    )
        with self.assertRaisesRegex(ValueError, 'Arquivo extra'):
            pipeline.apply_edits_and_zip(zip_bytes=source, edits=[], extra_files={'../bad.py': 'print(0)'})

    def test_generated_files_have_manifest_and_known_syntax_gate(self):
        valid = pipeline.build_zip_from_files({'src/main.py': 'X = 1\n', 'lib/main.dart': 'void main() {}\n'})
        self.assertEqual(len(valid['file_manifest']['files']), 2)
        self.assertEqual(valid['source_validation']['status'], 'partial')
        self.assertEqual(len(valid['file_manifest']['files'][0]['sha256']), 64)
        with self.assertRaisesRegex(ValueError, 'sintáticos'):
            pipeline.build_zip_from_files({'broken.py': 'def broken(:\n'})

    def test_unsupported_dart_does_not_crowd_out_python_validation(self):
        from app.core.document_builder.validator import validate_source_archive
        sample = {f'lib/file_{i:03d}.dart': 'void main() {}' for i in range(60)}
        sample['src/broken.py'] = 'def broken(:'
        raw = zip_input(sample)
        outcome = validate_source_archive(raw, max_files=1)
        self.assertEqual(outcome['issue_count'], 1)
        self.assertEqual(outcome['issues'][0]['path'], 'src/broken.py')

    def test_duplicate_normalized_paths_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'duplicados'):
            build_zip_from_mapping({'lib\\A.dart': 'x', 'lib/a.dart': 'y'})

    def test_snapshot_ignores_junk_and_reports_deletions(self):
        root = Path(self.temp.name) / 'tree'
        (root / 'src').mkdir(parents=True)
        (root / '.git').mkdir()
        (root / 'src' / 'a.py').write_text('a')
        (root / '.git' / 'HEAD').write_text('secret')
        before = snapshot_tree(root)
        self.assertEqual(list(before), ['src/a.py'])
        (root / 'src' / 'a.py').unlink()
        report = compare_snapshots(before, snapshot_tree(root))
        self.assertEqual(report['counts']['deleted'], 1)

    def test_project_zip_does_not_claim_missing_indexed_files_are_included(self):
        pid = new_project_id()
        save_meta(pid, {
            'user_id': 'default', 'scan_root': '.',
            'map': {'files': [{'path': 'a.py'}, {'path': 'missing.py'}]},
        })
        root = workspace(pid)
        root.mkdir(parents=True, exist_ok=True)
        (root / 'a.py').write_text('x = 1\n')
        result = pipeline.build_zip_from_project(pid)
        self.assertEqual(result['source_coverage']['indexed_files'], 2)
        self.assertEqual(result['source_coverage']['missing_indexed_files'], 1)
        self.assertFalse(result['source_coverage']['complete_as_indexed'])

    def test_deep_review_reports_assessed_source_hashes(self):
        from app.core.code_analyzer.deep_review import run_deep_review
        pid = new_project_id()
        source = {'README.md': '# Demo\n', 'src/main.py': 'x = 1\n'}
        root = workspace(pid)
        for name, value in source.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value)
        save_meta(pid, {'user_id': 'default', 'scan_root': '.',
                        'source': {'type': 'zip'},
                        'map': {'files': [{'path': k, 'size': len(v)} for k, v in source.items()]}})
        class Model:
            async def chat_once(self, model, messages, **kwargs):
                return 'Sem falhas comprovadas.'
        result = asyncio.run(run_deep_review(pid, 'Revise o projeto completo',
                                             model_client=Model(), model='test'))
        self.assertTrue(result['ok'])
        coverage = result['coverage']
        self.assertEqual(coverage['llm_assessed_files'], 2)
        self.assertTrue(all(len(hash_value) == 64 for hash_value in coverage['source_hashes'].values()))
        self.assertEqual(coverage['not_assessed_paths'], [])

    def test_review_plan_requires_project_ownership(self):
        pid = new_project_id()
        save_meta(pid, {'user_id': 'alice', 'map': {'files': [
            {'path': 'README.md'}, {'path': 'src/main.py'}, {'path': 'tests/test_a.py'}
        ]}})
        with self.assertRaises(HTTPException) as ctx:
            asyncio.run(project_review_plan(pid, user_id='bob'))
        self.assertEqual(ctx.exception.status_code, 404)
        result = asyncio.run(project_review_plan(pid, user_id='alice'))
        self.assertEqual(result['eligible_files'], 3)
        self.assertEqual(result['omitted_files'], 0)
        self.assertIn('Plano de leitura', result['note'])


if __name__ == '__main__':
    unittest.main()
