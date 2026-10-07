from pydantic import BaseModel


class ExploreVideo(BaseModel):
    id: str
    title: str
    url: str
    thumbnail: str | None = None
    channel: str | None = None
    channel_id: str | None = None
    duration: int | None = None
    duration_string: str | None = None
    view_count: int | None = None
    views_label: str | None = None
    age: str | None = None
    provider: str = "youtube"


class ExploreSearchResponse(BaseModel):
    success: bool = True
    query: str
    page: int = 1
    has_more: bool = False
    results: list[ExploreVideo]


class TrendingResponse(BaseModel):
    success: bool = True
    source: str = "search"
    results: list[ExploreVideo]


class LinkMetadataResponse(BaseModel):
    success: bool = True
    provider: str
    playable: bool = False
    downloadable: bool = True
    reason: str | None = None
    video: ExploreVideo | None = None


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


class StreamUrlResponse(BaseModel):
    success: bool = True
    video: str | None = None
    audio: str | None = None
    proxy: str | None = None
    title: str | None = None
    channel: str | None = None
    channel_avatar: str | None = None
    comment_count: int | None = None
    duration: int | None = None
    description: str | None = None


class PlayUrlResponse(BaseModel):
    success: bool = True
    url: str
    format_id: str
    ext: str
    height: int | None = None
