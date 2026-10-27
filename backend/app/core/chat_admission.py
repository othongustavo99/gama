"""Atomic, process-local admission control for active chat generations.

The same assistant message ID may only have one active request per account.
Optional capacity limits default to off until a measured staging rollout.
This is NOT a distributed limiter: deploying multiple workers requires shared
coordination before claiming cluster-wide limits.
"""
from __future__ import annotations

import os
import threading
import uuid
from dataclasses import dataclass, field


def _limit(name: str) -> int:
    raw = os.getenv(name, '0').strip()
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f'{name} deve ser um inteiro >= 0') from exc
    if not 0 <= value <= 1000:
        raise ValueError(f'{name} deve estar entre 0 e 1000')
    return value


class AdmissionRejected(Exception):
    def __init__(self, status_code: int, message: str):
        self.status_code = status_code
        super().__init__(message)


@dataclass(eq=False)
class Admission:
    registry: 'ChatAdmissionRegistry'
    owner: str
    message_id: str
    producer_started: bool = False
    _released: bool = field(default=False, repr=False)

    def release(self) -> None:
        self.registry.release(self)

    def transfer_to_producer(self) -> None:
        """Once work starts, its task callback must release the admission."""
        self.producer_started = True


class ChatAdmissionRegistry:
    def __init__(self):
        self._lock = threading.RLock()
        self._active: dict[tuple[str, str], Admission] = {}
        self._owners: dict[str, int] = {}

    def reserve(self, owner: str, message_id: str | None) -> Admission:
        if not owner or not isinstance(owner, str):
            raise ValueError('Identidade autenticada obrigatória')
        identifier = (message_id or '').strip() or uuid.uuid4().hex
        key = (owner, identifier)
        with self._lock:
            if key in self._active:
                raise AdmissionRejected(409, 'Esta resposta já está sendo processada. Aguarde a conclusão antes de reenviar.')
            per_user = _limit('GAMA_CHAT_MAX_ACTIVE_PER_USER')
            global_max = _limit('GAMA_CHAT_MAX_ACTIVE_GLOBAL')
            if per_user and self._owners.get(owner, 0) >= per_user:
                raise AdmissionRejected(429, 'Você já tem respostas em processamento. Aguarde a conclusão de uma delas.')
            if global_max and len(self._active) >= global_max:
                raise AdmissionRejected(503, 'A Gamma está ocupada no momento. Tente novamente em instantes.')
            admission = Admission(self, owner, identifier)
            self._active[key] = admission
            self._owners[owner] = self._owners.get(owner, 0) + 1
            return admission

    def release(self, admission: Admission) -> None:
        key = (admission.owner, admission.message_id)
        with self._lock:
            if self._active.get(key) is not admission:
                return
            self._active.pop(key)
            new_count = self._owners[admission.owner] - 1
            if new_count:
                self._owners[admission.owner] = new_count
            else:
                self._owners.pop(admission.owner, None)
            admission._released = True

    def snapshot(self) -> dict[str, int]:
        """Only aggregate counts; never reveal user IDs or message IDs."""
        with self._lock:
            return {'active': len(self._active), 'active_users': len(self._owners)}


chat_admissions = ChatAdmissionRegistry()
