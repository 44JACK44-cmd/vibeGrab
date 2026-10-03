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


class RelatedVideo(BaseModel):
    id: str
    title: str
    channel: str | None = None
    views: str | None = None
    views_label: str | None = None
    age: str | None = None
    duration: str | None = None
    thumbnail: str


class RelatedResponse(BaseModel):
    success: bool = True
    items: list[RelatedVideo]


class CommentItem(BaseModel):
    author: str
    avatar: str | None = None
    text: str
    published: str | None = None
    likes: str | None = None
    replies: str | None = None
    verified: bool = False
    pinned_text: str | None = None


class CommentsResponse(BaseModel):
    success: bool = True
    items: list[CommentItem]
    next_token: str | None = None
