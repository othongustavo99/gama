from typing import Any, List, Optional, Union

from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    role: str
    # str normal OU lista multimodal OpenAI (text + image_url)
    content: Union[str, List[Any]] = ""


class ChatImage(BaseModel):
    """Imagem em base64 puro (sem prefixo data:)."""
    mime: str = "image/jpeg"
    data: str  # base64
    name: str = "image"


class ChatRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    images: Optional[List[ChatImage]] = Field(default=None)
