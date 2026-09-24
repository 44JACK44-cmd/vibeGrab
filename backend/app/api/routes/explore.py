from fastapi import APIRouter
from fastapi.responses import JSONResponse
from app.schemas.explore import ExploreSearchResponse
from app.services.explore_service import search_videos
from app.core.logging import logger

router = APIRouter(prefix="/api/explore")


@router.get("/search")
def search(q: str, limit: int = 10):
    if not q or not q.strip():
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Search query is required"},
        )

    limit = max(1, min(limit, 20))

    try:
        results = search_videos(q.strip(), limit=limit)
        return ExploreSearchResponse(query=q.strip(), results=results)
    except Exception as e:
        logger.error(f"Search failed: {e}")
        return JSONResponse(
            status_code=500,
            content={"success": False, "detail": f"Search failed: {str(e)}"},
        )
