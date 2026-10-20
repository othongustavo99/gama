from fastapi import APIRouter, Query

from ..web_search import search_web, search_and_format

router = APIRouter(prefix="/search", tags=["search"])


@router.get("")
async def search(
    q: str = Query(..., min_length=2, max_length=300),
    limit: int = Query(5, ge=1, le=8),
):
    """Endpoint de teste da busca na web."""
    results = await search_web(q, max_results=limit)
    return {
        "query": q,
        "count": len(results),
        "results": results,
    }


@router.get("/formatted")
async def search_formatted(
    q: str = Query(..., min_length=2, max_length=300),
    limit: int = Query(5, ge=1, le=8),
):
    text = await search_and_format(q, max_results=limit)
    return {"query": q, "text": text}
