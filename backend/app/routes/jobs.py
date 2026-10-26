"""Consulta autenticada ao histórico de gerações de longa duração."""
from fastapi import APIRouter, Depends, HTTPException

from ..core.identity import current_user_id
from ..core.long_jobs import get, list_jobs

router = APIRouter(prefix="/jobs", tags=["jobs"])


@router.get("")
async def job_list(user_id: str = Depends(current_user_id)):
    return {"ok": True, "jobs": list_jobs(user_id)}


@router.get("/{job_id}")
async def job_detail(job_id: str, user_id: str = Depends(current_user_id)):
    item = get(user_id, job_id)
    if item is None:
        raise HTTPException(404, "Trabalho não encontrado")
    return {"ok": True, "job": item}
