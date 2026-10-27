"""Fase 3J: health probes, admin operational metrics, encrypted recoverable backups."""
from __future__ import annotations

import base64
import importlib.util
import os
import sqlite3
from pathlib import Path

import httpx
import pytest
from cryptography.exceptions import InvalidTag

from app.core.ops_observability import record_response, route_group, snapshot
from app.main import app


def load_script(filename: str):
    script_path = Path(__file__).resolve().parents[1] / 'scripts' / filename
    spec = importlib.util.spec_from_file_location(filename.replace('.py', ''), script_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_telemetry_never_exposes_dynamic_paths():
    assert route_group('/artifacts/user-secret/private.zip?purchaseToken=S3CR3T') == 'artifacts'
    assert route_group('/something_private/user-1234') == 'other'
    record_response('/chat/unique-client-id?access_token=private', 200, 17.8)
    record_response('/chat/unique-client-id', 502, 99.9)
    overview = snapshot(15)
    assert overview['route_groups'].get('chat', 0) >= 2
    assert overview['status_classes']['5xx'] >= 1
    assert 'private' not in str(overview)
    assert 'unique-client-id' not in str(overview)


@pytest.mark.asyncio
async def test_public_readiness_returns_only_generic_status(monkeypatch):
    from app import main
    monkeypatch.delenv('RAILWAY_PROJECT_ID', raising=False)
    monkeypatch.delenv('GAMA_REQUIRE_PERSISTENT_STORAGE', raising=False)
    monkeypatch.setattr(main, 'current_storage_status', lambda: {'writable': True, 'persistent': False})
    response = await main.readiness()
    assert response == {'status': 'ready'}
    monkeypatch.setenv('RAILWAY_PROJECT_ID', 'project-test')
    response = await main.readiness()
    assert response.status_code == 503
    assert b'/data' not in response.body
    monkeypatch.setattr(main, 'current_storage_status', lambda: {'writable': True, 'persistent': True})
    assert (await main.readiness()) == {'status': 'ready'}


def test_admin_ops_uses_existing_admin_authorization():
    matches = [r for r in app.routes if getattr(r, 'path', '') == '/admin/ops']
    assert matches, 'Ops router not registered'
    deps = matches[0].dependant.dependencies
    assert any(getattr(d.call, '__name__', '') == 'require_admin' for d in deps)


def test_encrypted_backup_sqlite_and_recovery(tmp_path):
    backup = load_script('secure_backup.py')
    source = tmp_path / 'data'
    source.mkdir()
    (source / 'histories').mkdir()
    (source / 'histories' / 'history.json').write_text('{"msg":"saved"}', encoding='utf8')
    dbfile = source / 'gama.sqlite3'
    with sqlite3.connect(dbfile) as db:
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE notes (value TEXT)')
        db.execute('INSERT INTO notes VALUES (?)', ('kept',))
        db.commit()
    key = os.urandom(32)
    archive = tmp_path / 'backup.gbackup'
    result = backup.create(source, archive, key)
    assert result['files'] == 2
    assert b'"msg":"saved"' not in archive.read_bytes()
    assert backup.verify_or_restore(archive, key)['files_verified'] == 2
    restored = tmp_path / 'restored'
    backup.verify_or_restore(archive, key, restored)
    assert (restored / 'histories' / 'history.json').read_text() == '{"msg":"saved"}'
    with sqlite3.connect(restored / 'gama.sqlite3') as db:
        assert db.execute('SELECT value FROM notes').fetchone()[0] == 'kept'
    with pytest.raises(FileExistsError):
        backup.verify_or_restore(archive, key, restored)
    with pytest.raises(InvalidTag):
        backup.verify_or_restore(archive, os.urandom(32))


def test_backup_refuses_archive_inside_data_or_symlinks(tmp_path):
    backup = load_script('secure_backup.py')
    src = tmp_path / 'data'
    src.mkdir()
    (src / 'file.txt').write_text('hello')
    key = os.urandom(32)
    with pytest.raises(ValueError):
        backup.create(src, src / 'inside.gbackup', key)
    if hasattr(os, 'symlink'):
        (src / 'link').symlink_to(tmp_path, target_is_directory=True)
        with pytest.raises(ValueError):
            backup.create(src, tmp_path / 'outside.gbackup', key)


def test_smoke_load_only_allows_safe_probe():
    script = load_script('smoke_load.py')
    with pytest.raises(ValueError):
        script.run('http://127.0.0.1:8000', 10, 4, '/chat')
    with pytest.raises(ValueError):
        script.run('http://127.0.0.1:8000', 501, 10, '/ready')
