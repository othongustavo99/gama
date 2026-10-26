"""Persistência de artefatos ZIP/PDF no volume configurado em DATA_DIR."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Optional


def _positive_env(name: str, default: int) -> int:
    try:
        return max(1, int(os.getenv(name, str(default))))
    except (TypeError, ValueError):
        return default


# Deixa espaço no volume de 5 GB para índices, memória e demais dados da Gama.
_TTL_SEC = _positive_env("ARTIFACT_TTL_HOURS", 24 * 7) * 3600
_MAX_TOTAL_BYTES = _positive_env("ARTIFACT_STORAGE_LIMIT_MB", 3072) * 1024 * 1024
_MAX_FILE_BYTES = _positive_env("ARTIFACT_MAX_FILE_MB", 100) * 1024 * 1024
_STORE_LOCK = threading.RLock()
_ID_RE = re.compile(r"^[a-f0-9]{16}$")


class ArtifactStorageLimitError(ValueError):
    """O volume atingiu o limite configurado para artefatos."""


def _root() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    base = Path(env) if env else Path(__file__).resolve().parents[3] / "data"
    p = base / "artifacts"
    p.mkdir(parents=True, exist_ok=True)
    return p


def new_artifact_id() -> str:
    return uuid.uuid4().hex[:16]


def artifact_dir(artifact_id: str) -> Path:
    if not _ID_RE.fullmatch(artifact_id or ""):
        raise ValueError("ID de artefato inválido")
    return _root() / artifact_id


def _used_bytes(root: Path) -> int:
    total = 0
    for child in root.iterdir():
        if child.is_dir():
            for path in child.iterdir():
                if path.is_file() and path.name != ".meta.tmp":
                    try:
                        total += path.stat().st_size
                    except OSError:
                        pass
    return total


def save_artifact(
    *,
    kind: str,
    filename: str,
    data: bytes,
    meta: Optional[dict[str, Any]] = None,
    user_id: str = "default",
) -> dict[str, Any]:
    from ..account_privacy import deletion_status
    if deletion_status(user_id) != "active":
        raise PermissionError("Conta excluída: não é permitido salvar novos arquivos")
    if not isinstance(data, bytes):
        data = bytes(data)
    if not data:
        raise ValueError("O arquivo gerado está vazio")
    if len(data) > _MAX_FILE_BYTES:
        raise ArtifactStorageLimitError(
            f"O arquivo excede o limite de {_MAX_FILE_BYTES // (1024 * 1024)} MB"
        )

    with _STORE_LOCK:
        cleanup_old()
        root = _root()
        if _used_bytes(root) + len(data) > _MAX_TOTAL_BYTES:
            raise ArtifactStorageLimitError(
                "O armazenamento de arquivos gerados atingiu o limite. Tente novamente mais tarde."
            )

        aid = new_artifact_id()
        d = artifact_dir(aid)
        d.mkdir(parents=True, exist_ok=False)
        safe_name = filename.replace("\\", "/").split("/")[-1]
        safe_name = "".join(c for c in safe_name if ord(c) >= 32 and ord(c) != 127)
        safe_name = safe_name.replace("..", "_") or f"file.{kind}"
        path = d / safe_name
        temp_path = d / ".artifact.tmp"
        try:
            temp_path.write_bytes(data)
            temp_path.replace(path)
            now = time.time()
            # Dados auxiliares não podem substituir o proprietário, o caminho
            # nem o checksum. Mesmo um chamador interno pode receber metadados
            # gerados por um modelo de IA ou por outro serviço.
            reserved = {
                "artifact_id", "kind", "filename", "size", "user_id",
                "created_at", "expires_at", "path", "sha256", "bytes",
            }
            extras = {k: v for k, v in (meta or {}).items() if k not in reserved}
            info = {
                **extras,
                "artifact_id": aid,
                "kind": kind,
                "filename": safe_name,
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "user_id": user_id,
                "created_at": now,
                "expires_at": now + _TTL_SEC,
                "path": str(path),
            }
            meta_tmp = d / ".meta.tmp"
            meta_tmp.write_text(
                json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            meta_tmp.replace(d / "meta.json")
            return info
        except Exception:
            shutil.rmtree(d, ignore_errors=True)
            raise


def _metadata(artifact_id: str, user_id: Optional[str] = None) -> Optional[dict[str, Any]]:
    try:
        d = artifact_dir(artifact_id)
        meta_path = d / "meta.json"
        if not meta_path.is_file():
            return None
        info = json.loads(meta_path.read_text(encoding="utf-8"))
        if user_id is not None and info.get("user_id", "default") != user_id:
            return None
        # Only accept a file directly inside this artifact directory.
        file_path = (d / Path(str(info.get("filename", ""))).name).resolve()
        if file_path.parent != d.resolve() or not file_path.is_file():
            return None
        created = float(info.get("created_at") or 0)
        expires = float(info.get("expires_at") or (created + _TTL_SEC))
        if time.time() >= expires:
            shutil.rmtree(d, ignore_errors=True)
            return None
        info["path"] = str(file_path)
        actual_size = file_path.stat().st_size
        # O usuário nunca deve receber um arquivo evidentemente incompleto.
        # Metadados legados podem não possuir SHA-256; o checksum é calculado
        # uma vez na leitura, sem sobrescrever o arquivo de metadados.
        if "size" in info and int(info["size"]) != actual_size:
            return None
        info["size"] = actual_size
        if not re.fullmatch(r"[a-fA-F0-9]{64}", str(info.get("sha256") or "")):
            info["sha256"] = _sha256_file(file_path)
        info["expires_at"] = expires
        return info
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return None


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_artifact_file(info: dict[str, Any]) -> bool:
    """Verifica os bytes em disco antes de enviá-los ao consumidor."""
    try:
        path = Path(info["path"])
        expected_size = int(info["size"])
        expected_hash = str(info.get("sha256") or "")
        return (path.is_file() and path.stat().st_size == expected_size
                and bool(re.fullmatch(r"[a-fA-F0-9]{64}", expected_hash))
                and _sha256_file(path) == expected_hash.lower())
    except (OSError, ValueError, TypeError, KeyError):
        return False


def load_artifact(
    artifact_id: str,
    user_id: Optional[str] = None,
    *,
    include_bytes: bool = False,
) -> Optional[dict[str, Any]]:
    info = _metadata(artifact_id, user_id)
    if not info:
        return None
    if include_bytes:
        try:
            info["bytes"] = Path(info["path"]).read_bytes()
        except OSError:
            return None
    return info


def list_recent(user_id: Optional[str] = None, limit: int = 20) -> list[dict[str, Any]]:
    root = _root()
    items: list[dict[str, Any]] = []
    for child in root.iterdir():
        if not child.is_dir():
            continue
        info = _metadata(child.name, user_id)
        if info:
            info.pop("path", None)
            items.append(info)
    items.sort(key=lambda x: -float(x.get("created_at") or 0))
    return items[: max(1, min(int(limit), 100))]


def cleanup_old(max_age: Optional[float] = None) -> None:
    root = _root()
    now = time.time()
    ttl = _TTL_SEC if max_age is None else max_age
    for child in root.iterdir():
        if not child.is_dir():
            continue
        meta = child / "meta.json"
        try:
            if meta.exists():
                data = json.loads(meta.read_text(encoding="utf-8"))
                created = float(data.get("created_at", 0))
                expires = float(data.get("expires_at") or (created + ttl))
                if now >= expires:
                    shutil.rmtree(child, ignore_errors=True)
            elif now - child.stat().st_mtime > ttl:
                shutil.rmtree(child, ignore_errors=True)
        except Exception:
            # Metadados inválidos não devem ocupar o volume indefinidamente.
            if now - child.stat().st_mtime > ttl:
                shutil.rmtree(child, ignore_errors=True)


def work_dir(job_id: Optional[str] = None) -> Path:
    """Diretório temporário isolado para edição/recompactação."""
    jid = job_id or new_artifact_id()
    env = os.getenv("DATA_DIR", "").strip()
    base = Path(env) if env else Path(__file__).resolve().parents[3] / "data"
    p = base / "builder_work" / jid
    p.mkdir(parents=True, exist_ok=True)
    return p
