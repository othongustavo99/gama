"""Portable, encrypted backup and restore drill for Gamma DATA_DIR.

Usage (key is a 32-byte base64url key in the named env variable):
  python scripts/secure_backup.py create --data-dir /data --archive /tmp/gamma.gbackup
  python scripts/secure_backup.py verify --archive /tmp/gamma.gbackup
  python scripts/secure_backup.py restore --archive /tmp/gamma.gbackup --destination /tmp/restore-drill

Always verify recovered files in an isolated directory. Do not replace a live volume.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import shutil
import sqlite3
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

MAGIC = b'GAMABK01'
CHUNK = 1024 * 1024
_EXCLUDE_NAMES = {'.git', '__pycache__', '.dart_tool', '.venv'}
_JOURNAL_SUFFIXES = ('-wal', '-shm', '-journal')


def key_from_env(name: str) -> bytes:
    raw = os.getenv(name, '')
    try:
        decoded = base64.urlsafe_b64decode(raw.encode('ascii'))
    except (ValueError, UnicodeError) as exc:
        raise ValueError(f'Invalid {name} (expected base64url encoding of 32 bytes)') from exc
    if len(decoded) != 32:
        raise ValueError(f'Missing/invalid {name}: expected 32 bytes; aborting')
    return decoded


def file_hash(file: Path) -> str:
    h = hashlib.sha256()
    with file.open('rb') as inp:
        for part in iter(lambda: inp.read(CHUNK), b''):
            h.update(part)
    return h.hexdigest()


def _stage_data(data_dir: Path, stage: Path) -> dict[str, str]:
    manifest: dict[str, str] = {}
    for path in sorted(data_dir.rglob('*')):
        rel = path.relative_to(data_dir)
        if any(part in _EXCLUDE_NAMES for part in rel.parts):
            continue
        if path.is_symlink():
            raise ValueError('DATA_DIR contains a symlink; backup stopped to avoid following an unsafe path')
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError('Unsupported file type in DATA_DIR')
        if path.name.endswith(_JOURNAL_SUFFIXES):
            continue
        target = stage / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix.lower() in {'.sqlite3', '.sqlite', '.db'}:
            # SQLite hot-backup API copies a consistent state including WAL.
            try:
                source = sqlite3.connect(f'file:{path.as_posix()}?mode=ro', uri=True, timeout=30)
                with source, sqlite3.connect(target, timeout=30) as destination:
                    source.backup(destination, pages=128, sleep=0.05)
                source.close()
            except sqlite3.DatabaseError as exc:
                raise ValueError('SQLite backup failed; no archive was created') from exc
        else:
            shutil.copy2(path, target)
        manifest[rel.as_posix()] = file_hash(target)
    return manifest


def _stream_encrypt(src: Path, out: Path, key: bytes) -> None:
    nonce = os.urandom(12)
    encryptor = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
    with src.open('rb') as inp, out.open('xb') as dest:
        dest.write(MAGIC + nonce)
        for part in iter(lambda: inp.read(CHUNK), b''):
            dest.write(encryptor.update(part))
        dest.write(encryptor.finalize())
        dest.write(encryptor.tag)


def _stream_decrypt(src: Path, out: Path, key: bytes) -> None:
    total = src.stat().st_size
    if total < len(MAGIC) + 12 + 16:
        raise ValueError('Backup incomplete')
    with src.open('rb') as inp:
        if inp.read(len(MAGIC)) != MAGIC:
            raise ValueError('Unknown backup format')
        nonce = inp.read(12)
        inp.seek(total - 16)
        tag = inp.read(16)
        inp.seek(len(MAGIC) + 12)
        remaining = total - len(MAGIC) - 12 - 16
        decryptor = Cipher(algorithms.AES(key), modes.GCM(nonce, tag)).decryptor()
        with out.open('xb') as dest:
            while remaining > 0:
                part = inp.read(min(CHUNK, remaining))
                if not part:
                    raise ValueError('Backup truncated')
                dest.write(decryptor.update(part))
                remaining -= len(part)
            decryptor.finalize()  # Raises InvalidTag on tampering or wrong key.


def create(data_dir: Path, archive: Path, key: bytes) -> dict:
    data_dir = data_dir.expanduser().resolve(strict=True)
    archive = archive.expanduser().resolve()
    if not data_dir.is_dir():
        raise ValueError('DATA_DIR must be an existing folder')
    if data_dir == archive or data_dir in archive.parents:
        raise ValueError('Archive must be outside DATA_DIR')
    if archive.exists():
        raise FileExistsError('Archive already exists; refusing to overwrite')
    if not archive.parent.is_dir():
        raise ValueError('Output folder does not exist')
    with tempfile.TemporaryDirectory(prefix='gama-backup-') as t:
        work = Path(t)
        stage = work / 'files'
        stage.mkdir()
        manifest = _stage_data(data_dir, stage)
        info = {
            'format': 1,
            'created_utc': datetime.now(timezone.utc).isoformat(),
            'files': manifest,
        }
        (stage / '_GAMMA_BACKUP_MANIFEST.json').write_text(
            json.dumps(info, sort_keys=True, ensure_ascii=False), encoding='utf-8')
        intermediate = work / 'snapshot.tar.gz'
        with tarfile.open(intermediate, 'w:gz') as tar:
            for f in sorted(stage.rglob('*')):
                if f.is_file():
                    tar.add(f, arcname=f.relative_to(stage).as_posix(), recursive=False)
        partial = archive.with_name(f'.{archive.name}.{secrets.token_hex(8)}.partial')
        try:
            _stream_encrypt(intermediate, partial, key)
            # Hardlink creation is atomic and refuses an already existing archive.
            os.link(partial, archive)
        finally:
            partial.unlink(missing_ok=True)
    return {'files': len(manifest), 'archive': str(archive), 'encrypted': True}


def _extract_verified(tarpath: Path, dest: Path) -> dict:
    seen: set[str] = set()
    manifest_bytes = None
    with tarfile.open(tarpath, 'r:gz') as archive:
        for member in archive:
            name = member.name
            parts = Path(name).parts
            if (not name or name.startswith('/') or '..' in parts or
                    not member.isfile() or name in seen):
                raise ValueError('Unsafe backup archive entry')
            seen.add(name)
            if name == '_GAMMA_BACKUP_MANIFEST.json':
                file = archive.extractfile(member)
                if file is None or member.size > 30 * 1024 * 1024:
                    raise ValueError('Invalid manifest')
                manifest_bytes = file.read()
                continue
            target = dest.joinpath(*parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError('Unexpected archive entry')
            with target.open('xb') as out:
                shutil.copyfileobj(stream, out, CHUNK)
    if manifest_bytes is None:
        raise ValueError('Backup manifest missing')
    manifest = json.loads(manifest_bytes)
    expected = manifest.get('files')
    if manifest.get('format') != 1 or not isinstance(expected, dict):
        raise ValueError('Invalid manifest schema')
    if (seen - {'_GAMMA_BACKUP_MANIFEST.json'}) != set(expected):
        raise ValueError('Archive contents do not match manifest')
    for relative, digest in expected.items():
        if not isinstance(digest, str) or file_hash(dest / relative) != digest:
            raise ValueError('Backup file digest mismatch')
    return {'files_verified': len(expected), 'created_utc': manifest.get('created_utc')}


def verify_or_restore(archive: Path, key: bytes, destination: Path | None = None) -> dict:
    archive = archive.expanduser().resolve(strict=True)
    if destination is not None:
        destination = destination.expanduser().resolve()
        if destination.exists():
            raise FileExistsError('Restore destination must not exist; never overwrite live data')
    with tempfile.TemporaryDirectory(prefix='gama-restore-') as t:
        work = Path(t)
        tarpath = work / 'decrypted.tar.gz'
        _stream_decrypt(archive, tarpath, key)
        checked = work / 'checked'
        checked.mkdir()
        result = _extract_verified(tarpath, checked)
        if destination is not None:
            shutil.copytree(checked, destination)
            result['restored_to'] = str(destination)
        return result


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description='Encrypted Gamma backups and restore drills')
    p.add_argument('action', choices=['create', 'verify', 'restore'])
    p.add_argument('--data-dir', type=Path)
    p.add_argument('--archive', type=Path, required=True)
    p.add_argument('--destination', type=Path)
    p.add_argument('--key-env', default='GAMA_BACKUP_KEY')
    args = p.parse_args(argv)
    if args.action == 'create' and args.data_dir is None:
        p.error('create requires --data-dir')
    if args.action == 'restore' and args.destination is None:
        p.error('restore requires --destination')
    key = key_from_env(args.key_env)
    result = (create(args.data_dir, args.archive, key) if args.action == 'create'
              else verify_or_restore(args.archive, key, args.destination if args.action == 'restore' else None))
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
