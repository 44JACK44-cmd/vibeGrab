from pydantic import BaseModel


class ExploreVideo(BaseModel):
    id: str
    title: str
    url: str
    thumbnail: str | None = None
    channel: str | None = None
    duration: int | None = None
    duration_string: str | None = None
    view_count: int | None = None


class ExploreSearchResponse(BaseModel):
    success: bool = True
    query: str
    results: list[ExploreVideo]
