"""Exclusão de dados por identidade autenticada e proteção contra ressinc.

Nunca confia num user_id enviado pelo cliente. DATA_DIR deve ser um diretório
privado administrado pelo servidor, sem escrita por usuários externos.
Uma lápide pseudonimizada impede recriação automática por clientes antigos.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)
_LOCK = threading.RLock()
_USER_RE = re.compile(r"^[A-Za-z0-9_.@-]{1,128}$")


def _base() -> Path:
    env = os.getenv("DATA_DIR", "").strip()
    return Path(env) if env else Path(__file__).resolve().parents[2] / "data"


def _safe_id(user_id: str) -> str:
    if not isinstance(user_id, str) or not _USER_RE.fullmatch(user_id) or user_id in {".", ".."}:
        raise ValueError("Identidade de conta inválida")
    # O armazenamento existente substitui caracteres fora de [\\w.-@] (IDs Google
    # gerados pela própria API estão sempre dentro desse intervalo).
    return user_id


def _marker(user_id: str) -> Path:
    uid = _safe_id(user_id)
    return _base() / "account_deletions" / (hashlib.sha256(uid.encode()).hexdigest() + ".json")


def deletion_status(user_id: str) -> str:
    path = _marker(user_id)
    if not path.exists():
        return "active"
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
        status = state.get("status")
        return status if status in {"deleting", "deleted"} else "deleting"
    except (OSError, ValueError, TypeError):
        # Falha fechada: metadados corrompidos nunca liberam acesso.
        return "deleting"


def _write_marker(user_id: str, status: str) -> None:
    marker = _marker(user_id)
    marker.parent.mkdir(parents=True, exist_ok=True)
    temp = marker.with_suffix(".tmp")
    temp.write_text(json.dumps({"status": status, "updated_at": datetime.now(timezone.utc).isoformat()}), encoding="utf-8")
    os.replace(temp, marker)


def start_new_account(user_id: str) -> None:
    """Recomeço explícito após exclusão irreversível (nunca restaura dados)."""
    with _LOCK:
        if deletion_status(user_id) != "deleted":
            raise ValueError("A conta não está pronta para recomeçar")
        _marker(user_id).unlink()


def _remove(target: Path, base: Path) -> bool:
    """Remove apenas caminhos dentro de DATA_DIR; não segue symlinks."""
    base_resolved = base.resolve()
    # resolve(strict=False) poderia atravessar um symlink — não aceitar.
    if target.is_symlink():
        raise OSError("link simbólico inesperado no armazenamento")
    if base_resolved not in target.parent.resolve().parents and target.parent.resolve() != base_resolved:
        raise OSError("caminho fora da área de dados")
    if not target.exists():
        return False
    if target.is_dir():
        shutil.rmtree(target)
    else:
        target.unlink()
    return True


def _owned_dirs(root: Path, user_id: str):
    if not root.is_dir():
        return
    for folder in root.iterdir():
        if not folder.is_dir() or folder.is_symlink():
            continue
        metadata = folder / "meta.json"
        try:
            if metadata.is_symlink() or not metadata.is_file():
                continue
            data = json.loads(metadata.read_text(encoding="utf-8"))
            if isinstance(data, dict) and data.get("user_id") == user_id:
                yield folder
        except (OSError, ValueError, TypeError):
            # Não remover conteúdos sem comprovação de propriedade.
            logger.warning("Metadado inválido em %s: revisão operacional necessária", root.name)


def _remove_quota(base: Path, user_id: str) -> bool:
    db_path = base / "gama_media_quota.sqlite3"
    if not db_path.is_file() or db_path.is_symlink():
        return False
    with sqlite3.connect(str(db_path), timeout=10) as db:
        # Compatível com instalações antigas que ainda não tenham a tabela.
        if not db.execute("SELECT 1 FROM sqlite_master WHERE name='media_quota'").fetchone():
            return False
        cursor = db.execute("DELETE FROM media_quota WHERE user_id=?", (user_id,))
        db.commit()
        return cursor.rowcount > 0


def delete_account_data(user_id: str) -> dict:
    """Bloqueia acesso antes de começar e faz limpeza reexecutável.

    Em falhas, retorna estado 'deleting'. Chamadas repetidas concluem o resto.
    O backend não possui ainda um coordenador de jobs distribuído; tarefas
    iniciadas antes da lápide exigem uma segunda varredura após encerramento.
    """
    uid = _safe_id(user_id)
    base = _base()
    with _LOCK:
        _write_marker(uid, "deleting")
        removed: list[str] = []
        errors: list[str] = []

        def cleanup(label: str, target: Path) -> None:
            try:
                if _remove(target, base):
                    removed.append(label)
            except (OSError, PermissionError) as exc:
                logger.warning("Exclusão incompleta de %s: %s", label, type(exc).__name__)
                errors.append(label)

        # Arquivos pessoais; mantém o histórico e dados de todos os outros usuários.
        for name in (f"{uid}.json", f"{uid}.json.bak"):
            cleanup("memória", base / "memory" / name)
        for name in (f"{uid}.sqlite3", f"{uid}.sqlite3-wal", f"{uid}.sqlite3-shm"):
            cleanup("memória v3", base / "memory_v3" / name)
        cleanup("conversas", base / "conversations" / f"{uid}.json")
        cleanup("conversas", base / "conversations" / uid)
        # SummaryStore utiliza caracteres \w.-; contexto usa chave de até 120.
        summary_uid = re.sub(r"[^\w\-\.@]+", "_", uid)[:120].strip(".") or "default"
        cleanup("resumos", base / "summaries" / f"{summary_uid}.json")
        # Chave de sessão: UID normalizado (máximo 80) seguido de __.
        session_prefix = re.sub(r"[^\w.\-]+", "_", uid)[:80] + "__"
        sessions = base / "conversation_sessions"
        if sessions.is_dir():
            for path in sessions.glob(session_prefix + "*.json"):
                cleanup("contexto temporário", path)
        video_dir = hashlib.sha256(uid.encode()).hexdigest()[:32]
        cleanup("jobs de vídeo", base / "video_jobs" / video_dir)
        for folder_name in ("projects", "artifacts"):
            root = base / folder_name
            for path in list(_owned_dirs(root, uid)):
                cleanup(folder_name, path)
        # Fase 1E: o journal de tarefas compartilha SQLite entre contas.
        try:
            from .long_jobs import delete_user
            if delete_user(uid):
                removed.append("histórico de tarefas")
        except (sqlite3.Error, OSError) as exc:
            logger.warning("Falha ao excluir histórico de tarefas: %s", type(exc).__name__)
            errors.append("histórico de tarefas")
        try:
            from .commercial_metrics import delete_user as delete_commercial_metrics
            if delete_commercial_metrics(uid):
                removed.append("métricas de utilização")
        except (sqlite3.Error, OSError) as exc:
            logger.warning("Falha ao limpar métricas: %s", type(exc).__name__)
            errors.append("métricas de utilização")
        try:
            from .usage_ledger import delete_user as delete_usage_ledger
            if delete_usage_ledger(uid):
                removed.append("custos e tokens")
        except (sqlite3.Error, OSError) as exc:
            logger.warning("Falha ao excluir livro de custos: %s", type(exc).__name__)
            errors.append("custos e tokens")
        try:
            from .commercial_plans import delete_user as delete_commercial_plan_data
            if delete_commercial_plan_data(uid):
                removed.append("planos e créditos de teste")
        except (sqlite3.Error, OSError) as exc:
            logger.warning("Falha ao excluir planos e créditos: %s", type(exc).__name__)
            errors.append("planos e créditos")
        try:
            from .play_reconciliation import delete_user as delete_play_events
            delete_play_events(uid)
            from .store_billing import delete_user as delete_play_checks
            if delete_play_checks(uid):
                removed.append("verificações de compras")
        except (sqlite3.Error, OSError) as exc:
            logger.warning("Falha ao excluir verificações de compras: %s", type(exc).__name__)
            errors.append("verificações de compras")
        try:
            if _remove_quota(base, uid):
                removed.append("cotas de mídia")
        except (sqlite3.Error, OSError) as exc:
            logger.warning("Falha ao excluir cota de mídia: %s", type(exc).__name__)
            errors.append("cotas de mídia")

        if not errors:
            _write_marker(uid, "deleted")
        return {
            "status": "deleted" if not errors else "deleting",
            "removed_categories": sorted(set(removed)),
            "incomplete_categories": sorted(set(errors)),
        }
