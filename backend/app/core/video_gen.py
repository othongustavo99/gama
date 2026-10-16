"""Detecção de intenção e geração assíncrona de vídeo pela API OpenRouter."""
from __future__ import annotations

import asyncio
import base64
import logging
import re
from dataclasses import dataclass
from enum import Enum
from typing import Any, AsyncIterator, Optional

import httpx

from ..config import settings

logger = logging.getLogger(__name__)
DEFAULT_VIDEO_MODEL = "bytedance/seedance-2.0-mini"


class VideoIntent(str, Enum):
    CREATE = "create"       # texto -> vídeo
    ANIMATE = "animate"     # imagem -> vídeo
    EDIT = "edit"           # vídeo existente como referência
    IMPROVE = "improve"     # refazer/aprimorar vídeo existente
    ANALYZE = "analyze"     # análise textual de quadros do vídeo
    NONE = "none"


@dataclass(frozen=True)
class VideoRequest:
    intent: VideoIntent
    prompt: str
    confidence: float


_VIDEO_WORD = re.compile(r"(?i)\b(v[ií]deo|videos|vídeos|clipe|clipes|filmagem|grava[cç][aã]o|video)\b")
_IMAGE_WORD = re.compile(r"(?i)\b(imagem|imagens|foto|fotos|fotografia|ilustra[cç][aã]o|picture|image)\b")
_ANALYZE = re.compile(r"(?i)\b(analisa(?:r|e)?|an[aá]lise|descrev(?:a|e|er)|resum(?:a|ir)|explique|explora(?:r)?|identifique|transcrev(?:a|er)|o que acontece|o que est[aá] acontecendo|o que aparece|o que [eé] isso|what happens|summari[sz]e|analy[sz]e)\b")
_EDIT = re.compile(r"(?i)\b(edita(?:r|e)?|edite|modifica(?:r|e)?|altera(?:r|e)?|muda(?:r|e)?|troca(?:r|e)?|substitui(?:r|a)?|estende(?:r)?|continue|continua(?:r)?|remonta(?:r)?|recria(?:r|e)?|transforma(?:r|e)?|corta(?:r|e)?|recorta(?:r|e)?|remove|remova|adicione|adiciona)\b")
_IMPROVE = re.compile(r"(?i)\b(melhora(?:r|e)?|melhore|aprimora(?:r|e)?|refina(?:r|e)?|aumenta(?:r|e)?\s+a\s+qualidade|estabiliza(?:r|e)?|upscale|enhance|improve|sharpen)\b")
_ANIMATE = re.compile(r"(?i)\b(anima(?:r|e)?|movimenta(?:r|e)?|dar movimento|transforma(?:r|e)?\s+(?:esta|essa|a)\s+imagem\s+em\s+v[ií]deo|image.to.video|animate)\b")
_IMAGE_TO_VIDEO = re.compile(r"(?i)\b(a\s+partir\s+d(?:a|e)\s+(?:imagem|foto)|usando\s+(?:esta|essa|a)?\s*(?:imagem|foto)(?:\s+como\s+refer[eê]ncia)?|com\s+(?:esta|essa|a|uma)?\s*(?:imagem|foto)|(?:esta|essa)\s+imagem\s+em\s+v[ií]deo|a\s+partir\s+d(?:o|e)\s+anexo|usando\s+(?:o\s+)?anexo|com\s+(?:o\s+)?anexo|from\s+the\s+attachment|turn\s+(?:this\s+)?image\s+into\s+(?:a\s+)?video)\b")
_CREATE = re.compile(r"(?i)\b(cria(?:r|e)?|crie|gere|gera(?:r)?|faz(?:er)?|fa[cç]a|produz(?:ir|a)?|imagina(?:r)?|imagine|monta(?:r|e)?|create|generate|make)\b")
_REFERENCE_VIDEO = re.compile(r"(?i)\b(com\s+base\s+(?:n[oa]|em)\s+(?:este|esse|nesse|no|o)?\s*v[ií]deo|a\s+partir\s+(?:d[oa]|desse|deste)\s+v[ií]deo|usando\s+(?:este|esse|o)?\s*v[ií]deo\s+como\s+refer[eê]ncia|use\s+(?:este|esse|o)?\s*v[ií]deo|baseado\s+n(?:o|este|esse)\s*v[ií]deo)\b")
_FROM_SCRATCH = re.compile(r"(?i)\b(do\s+zero|sem\s+(?:usar|aproveitar)\s+(?:este|esse|o)?\s*v[ií]deo|ignore\s+(?:este|esse|o)?\s*v[ií]deo)\b")
_INFO_REQUEST = re.compile(r"(?i)^\s*(?:como|de que forma|qual a melhor forma|me ensine|me ensina|explique|explique-me|passo a passo|quais ferramentas|qual ferramenta|o que [eé])\b")
_ASK_ADVICE = re.compile(r"(?i)\b(como\s+(?:eu\s+)?(?:posso|poderia|devo|deveria)\s+melhorar|o\s+que\s+(?:(?:voc[eê]\s+)?(?:acha|mudaria|poderia\s+melhorar)|(?:eu\s+)?(?:posso|poderia|devo|deveria)\s+(?:melhorar|mudar))|quais\s+(?:s[aã]o\s+)?(?:os\s+)?melhorias|sugest[oõ]es\s+de\s+melhoria|avalie\s+(?:a\s+)?qualidade)\b")

def _clean_text(text: str) -> str:
    """Remove marcadores/rótulos que o app adiciona; eles não são intenção do usuário."""
    text = re.sub(r"\[video_artifact_id:[A-Za-z0-9_-]{8,64}\]", "", text or "", flags=re.I)
    text = re.sub(r"\[project_id:[A-Za-z0-9_-]{6,128}\]", "", text, flags=re.I)
    text = re.sub(r"(?im)^\s*(?:v[ií]deo|video) anexado\s*:\s*[^\n]*(?:\n|$)", " ", text)
    text = re.sub(r"(?im)^\s*\[arquivo:[^\]]+\]\s*$", " ", text)
    return re.sub(r"\s+", " ", text).strip()

def detect_video_intent(
    user_text: str,
    *,
    has_attached_video: bool = False,
    has_attached_images: bool = False,
) -> VideoRequest:
    """Distingue análise, criação, animação e edição sem confundir rótulos do app."""
    text = _clean_text(user_text)
    if not text:
        return VideoRequest(VideoIntent.ANALYZE, "", 0.96) if has_attached_video else VideoRequest(VideoIntent.NONE, "", 0.0)

    has_video_word = bool(_VIDEO_WORD.search(text))
    has_image_word = bool(_IMAGE_WORD.search(text))
    analyze = bool(_ANALYZE.search(text))
    edit = bool(_EDIT.search(text))
    improve = bool(_IMPROVE.search(text))
    create = bool(_CREATE.search(text))
    advice = bool(_ASK_ADVICE.search(text))

    # Se a pessoa fala de uma imagem, não sequestrar a ação por um vídeo anexado antes.
    if has_attached_video and has_image_word and not has_video_word and not _REFERENCE_VIDEO.search(text):
        return VideoRequest(VideoIntent.NONE, "", 0.0)

    # Perguntas sobre como melhorar são análises, não autorização para editar.
    explicit_change = bool(re.search(r"(?i)\b(melhore|melhora|aprimora|aprimore|estabiliza|edite|edita|modifique|corte|recorte|remova|adicione)\b", text))
    if has_attached_video and advice and not explicit_change:
        return VideoRequest(VideoIntent.ANALYZE, text, 0.91)

    # Pergunta conceitual/tutorial sobre editar ou criar vídeo não deve abrir uma geração.
    if _INFO_REQUEST.search(text):
        return VideoRequest(VideoIntent.NONE, "", 0.0)

    if has_attached_video and improve:
        return VideoRequest(VideoIntent.IMPROVE, text, 0.94)
    if has_attached_video and edit:
        return VideoRequest(VideoIntent.EDIT, text, 0.93)
    if has_attached_video and analyze and (has_video_word or not has_image_word):
        return VideoRequest(VideoIntent.ANALYZE, text, 0.97)

    # Ao anexar vídeo e pedir outro vídeo baseado nele, use a referência de vídeo.
    if has_attached_video and has_video_word and create and not _FROM_SCRATCH.search(text):
        return VideoRequest(VideoIntent.EDIT, text, 0.88)

    if has_attached_images and (_ANIMATE.search(text) or _IMAGE_TO_VIDEO.search(text)):
        return VideoRequest(VideoIntent.ANIMATE, text, 0.93)
    if has_video_word and analyze:
        return VideoRequest(VideoIntent.ANALYZE, text, 0.86 if has_attached_video else 0.58)
    if has_video_word and improve:
        return VideoRequest(VideoIntent.IMPROVE, text, 0.90 if has_attached_video else 0.65)
    if has_video_word and edit:
        return VideoRequest(VideoIntent.EDIT, text, 0.90 if has_attached_video else 0.65)
    if (has_video_word and create) or re.search(r"(?i)\b(video|v[ií]deo)\s+(?:de|sobre|com)", text):
        return VideoRequest(VideoIntent.CREATE, text, 0.88)

    # Anexo sem instrução explícita: compreendê-lo é o padrão. Uma pergunta não
    # relacionada (ex.: clima) continua no fluxo de conversa normal.
    if has_attached_video and has_video_word:
        return VideoRequest(VideoIntent.ANALYZE, text, 0.80)
    return VideoRequest(VideoIntent.NONE, "", 0.0)


def parse_video_options(user_text: str) -> dict[str, Any]:
    """Extrai opções simples do pedido e mantém duração/resolução dentro dos limites."""
    text = _clean_text(user_text).lower()
    duration = int(getattr(settings, "VIDEO_GEN_DEFAULT_DURATION", 5))
    max_duration = int(getattr(settings, "VIDEO_GEN_MAX_DURATION", 10))
    match = re.search(r"\b(\d{1,2})\s*(?:s|seg(?:undo)?s?|seconds?)\b", text)
    if match:
        duration = max(4, min(int(match.group(1)), max_duration))
    resolution = "480p"
    if re.search(r"\b(720p|hd|alta\s+resolu[cç][aã]o|full\s*hd|1080p|2k|4k)\b", text):
        resolution = "720p"  # Seedance 2.0 Mini: até 720p; evita prometer 1080p não suportado.
    aspect_ratio = "16:9"
    if re.search(r"\b(vertical|reels|stories|story|tiktok|shorts|retrato|9:16)\b", text):
        aspect_ratio = "9:16"
    elif re.search(r"\b(quadrad[oa]|1:1)\b", text):
        aspect_ratio = "1:1"
    elif re.search(r"\b(horizontal|paisagem|widescreen|16:9)\b", text):
        aspect_ratio = "16:9"
    generate_audio = not bool(
        re.search(
            r"(?i)\b(sem\s+som|sem\s+áudio|sem\s+audio|mudo|vídeo\s+mudo|silencioso|silenciosa|mute|silent|no\s+audio)\b",
            text,
        )
    )
    return {
        "duration": duration,
        "resolution": resolution,
        "aspect_ratio": aspect_ratio,
        "generate_audio": generate_audio,
    }

def build_video_prompt(user_text: str, intent: VideoIntent) -> str:
    text = _clean_text(user_text)
    # Remove o comando principal sem apagar os detalhes de cena do usuário.
    text = re.sub(
        r"(?i)^\s*(por favor\s+)?(?:cria|crie|criar|gera|gere|gerar|faz|faça|fazer|produza|produzir|imagina|imaginar|anime|anima|anima(?:r|e)?|edita|edite|editar|melhore|melhorar)\s+",
        "", text,
    ).strip()
    if not text:
        text = "Cena curta cinematográfica, movimento natural e composição visual coerente."
    directives = {
        VideoIntent.CREATE: "Create a coherent short video from this description.",
        VideoIntent.ANIMATE: "Animate the supplied image as the visual first frame; preserve subject identity and style.",
        VideoIntent.EDIT: "Use the supplied video as a reference and create the requested edit while preserving temporal continuity.",
        VideoIntent.IMPROVE: "Use the supplied video as a reference and create a polished improved version, preserving its main subject and intent.",
    }
    directive = directives.get(intent, "Create a coherent short video.")
    return f"{directive}\nUser direction: {text[:3000]}\nPrioritize stable subjects, physically plausible movement, temporal consistency, clean transitions, and no unintended text or logos."


async def generate_video_events(
    prompt: str,
    *,
    model: Optional[str] = None,
    duration: Optional[int] = None,
    resolution: Optional[str] = None,
    aspect_ratio: Optional[str] = None,
    reference_images: Optional[list[dict[str, str]]] = None,
    reference_video_url: Optional[str] = None,
    generate_audio: bool = True,
    timeout_seconds: int = 420,
) -> AsyncIterator[dict[str, Any]]:
    """Submete job assíncrono, emite progresso e por fim bytes do vídeo.

    Eventos: {type: phase, phase: ...}; {type: completed, data: bytes, model, cost};
    {type: error, error: ...}. Não expõe chave, URLs temporárias nem respostas brutas.
    """
    if not getattr(settings, "VIDEO_GEN_ENABLED", True):
        yield {"type": "error", "error": "A geração de vídeo está desativada na configuração do backend."}
        return
    if settings.PROVIDER != "openrouter":
        yield {"type": "error", "error": "A geração de vídeo exige LLM_PROVIDER=openrouter."}
        return
    api_key = getattr(settings, "OPENROUTER_API_KEY", "")
    if not api_key:
        yield {"type": "error", "error": "OPENROUTER_API_KEY não está configurada no backend."}
        return

    model_id = (model or getattr(settings, "VIDEO_GEN_MODEL", None) or DEFAULT_VIDEO_MODEL).strip()
    seconds = int(duration or getattr(settings, "VIDEO_GEN_DEFAULT_DURATION", 5))
    # Seedance 2.0 Mini exige 4–15 s. Mantém a duração pedida dentro do
    # limite configurado sem enviar um pedido inválido de 1–3 segundos.
    configured_max = max(4, min(int(getattr(settings, "VIDEO_GEN_MAX_DURATION", 10)), 15))
    seconds = max(4, min(seconds, configured_max))
    res = (resolution or getattr(settings, "VIDEO_GEN_DEFAULT_RESOLUTION", "480p")).strip().lower()
    # Seedance 2.0 Mini/Fast public endpoints support 480p and 720p.
    low_cost_seedance = model_id in {
        "bytedance/seedance-2.0-mini",
        "bytedance/seedance-2.0-fast",
    }
    supported_resolutions = (
        {"480p", "720p"}
        if low_cost_seedance
        else {"480p", "720p", "768p", "1080p", "1k", "2k", "4k"}
    )
    if res not in supported_resolutions:
        res = "480p"
    ratio = (aspect_ratio or "16:9").strip()
    if ratio not in {"16:9", "9:16", "1:1", "4:3", "3:4", "3:2", "2:3", "21:9", "9:21"}:
        ratio = "16:9"

    payload: dict[str, Any] = {
        "model": model_id,
        "prompt": prompt[:4000],
        "duration": seconds,
        "resolution": res,
        "aspect_ratio": ratio,
        # Gera áudio por padrão; o parser desativa quando o usuário pede
        # explicitamente um clipe mudo/sem som.
        "generate_audio": bool(generate_audio),
    }
    if reference_video_url:
        payload["input_references"] = [{
            "type": "video_url",
            "video_url": {"url": reference_video_url},
        }]
    elif reference_images:
        first = next((img for img in reference_images if img.get("url") or img.get("data")), None)
        if first:
            image_url = str(first.get("url") or "").strip()
            if not image_url:
                mime = first.get("mime") or "image/jpeg"
                data = re.sub(r"\s+", "", str(first.get("data") or ""))
                image_url = f"data:{mime};base64,{data}"
            payload["frame_images"] = [{
                "type": "image_url",
                "image_url": {"url": image_url},
                "frame_type": "first_frame",
            }]

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": getattr(settings, "OPENROUTER_HTTP_REFERER", "") or getattr(settings, "APP_URL", "") or "https://gama.app",
        "X-Title": getattr(settings, "OPENROUTER_APP_TITLE", "Gama"),
    }
    base = getattr(settings, "OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")
    deadline = asyncio.get_running_loop().time() + max(60, min(timeout_seconds, 900))
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(60.0, connect=20.0), follow_redirects=True) as client:
            yield {"type": "phase", "phase": "video_queued"}
            response = await client.post(f"{base}/videos", headers=headers, json=payload)
            if response.status_code not in (200, 201, 202):
                body = response.text[:800]
                logger.warning("OpenRouter video submission failed status=%s body=%s", response.status_code, body)
                yield {"type": "error", "error": f"O provedor recusou o pedido de vídeo (HTTP {response.status_code}). Confira modelo, duração e saldo da OpenRouter."}
                return
            job = response.json()
            job_id = str(job.get("id") or "")
            if not re.fullmatch(r"[A-Za-z0-9_-]{4,128}", job_id):
                yield {"type": "error", "error": "O provedor não retornou um identificador válido para o vídeo."}
                return
            yield {"type": "phase", "phase": "video_generating"}
            poll_delay = 4.0
            latest: dict[str, Any] = job
            while asyncio.get_running_loop().time() < deadline:
                await asyncio.sleep(poll_delay)
                status_response = await client.get(f"{base}/videos/{job_id}", headers=headers)
                if status_response.status_code >= 400:
                    logger.warning("OpenRouter video polling failed status=%s", status_response.status_code)
                    yield {"type": "error", "error": f"Não consegui consultar o andamento do vídeo (HTTP {status_response.status_code})."}
                    return
                latest = status_response.json()
                status = str(latest.get("status") or "").lower()
                if status == "completed":
                    break
                if status == "failed":
                    provider_error = str(latest.get("error") or "")[:240]
                    yield {"type": "error", "error": "A geração de vídeo falhou no provedor." + (f" Detalhe: {provider_error}" if provider_error else " Tente uma descrição mais simples ou outro modelo.")}
                    return
                yield {"type": "phase", "phase": "video_generating"}
                poll_delay = min(poll_delay + 1.0, 8.0)
            else:
                yield {"type": "error", "error": "A geração demorou mais que o limite de espera. Tente novamente; o provedor pode ainda estar processando o pedido."}
                return

            yield {"type": "phase", "phase": "video_downloading"}
            content = await client.get(f"{base}/videos/{job_id}/content?index=0", headers=headers)
            if content.status_code >= 400:
                yield {"type": "error", "error": f"O vídeo foi gerado, mas não consegui baixá-lo do provedor (HTTP {content.status_code})."}
                return
            data = content.content
            if len(data) < 128 or not (data[4:8] == b"ftyp" or data.startswith(b"\x1aE\xdf\xa3")):
                yield {"type": "error", "error": "O provedor retornou um arquivo vazio ou em formato de vídeo não reconhecido; não salvei um artefato inválido."}
                return
            usage = latest.get("usage") if isinstance(latest.get("usage"), dict) else {}
            cost = usage.get("cost")
            yield {"type": "completed", "data": data, "model": model_id, "cost": cost, "duration": seconds, "resolution": res, "aspect_ratio": ratio, "generate_audio": bool(generate_audio), "content_type": content.headers.get("content-type", "video/mp4")}
    except httpx.TimeoutException:
        yield {"type": "error", "error": "A OpenRouter demorou demais para responder ao pedido de vídeo. Tente novamente."}
    except httpx.HTTPError as exc:
        logger.warning("OpenRouter video HTTP error: %s", type(exc).__name__)
        yield {"type": "error", "error": "Falha de conexão com o serviço de vídeo. Confira a conexão e tente novamente."}
    except Exception:
        logger.exception("Unexpected video generation error")
        yield {"type": "error", "error": "Ocorreu um erro inesperado ao gerar o vídeo."}
