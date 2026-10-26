from typing import Any, Dict, List, Optional, Union

from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    role: str
    id: Optional[str] = None
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
    user_id: Optional[str] = Field(default=None)
    # ID da conversa no app — mantém projeto/arquivos/ações entre mensagens
    conversation_id: Optional[str] = Field(default=None)
    assistant_message_id: Optional[str] = Field(default=None, max_length=128)
    auto_memory: bool = True
    # True quando o app pede resposta para ser falada (TTS)
    voice_mode: bool = False
    # programar | conversar — afeta system prompt e estilo de código
    chat_mode: Optional[str] = None
    # Preferências da Oficina e localização temporária (nunca credenciais).
    image_aspect_ratio: Optional[str] = None
    image_style: Optional[str] = None
    video_duration: Optional[int] = Field(default=None, ge=4, le=15)
    video_resolution: Optional[str] = None
    video_aspect_ratio: Optional[str] = None
    video_generate_audio: Optional[bool] = None
    location_context: Optional[str] = None
    # Capacidades selecionadas na tela Plugins do cliente. Chaves ausentes
    # preservam o comportamento padrão para clientes antigos.
    plugins: Dict[str, bool] = Field(default_factory=dict)
