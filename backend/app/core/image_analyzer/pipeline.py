"""Pipeline do Image Analyzer.

Estratégia de custo:
1. otimiza localmente a cópia da imagem;
2. faz UMA chamada visual curta para classificação/OCR/regiões;
3. entrega ao modelo principal somente o contexto visual compacto.

Assim a imagem não é reenviada ao modelo principal por padrão.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from .context_builder import compact_visual_context
from .preprocessor import prepare_many

logger = logging.getLogger(__name__)

ANALYZER_SYSTEM = """Você é o Image Analyzer da Gamma.
Sua função é enxergar de forma eficiente, não responder longamente ao usuário.

Analise as imagens conforme a pergunta do usuário. Classifique cada imagem
e extraia somente informações úteis para a resposta final.

Se houver texto, preserve literalmente o que for importante: erros, números,
nomes de arquivos, caminhos, código, títulos, labels, valores e linhas.
Não invente texto ilegível.

Identifique regiões relevantes quando fizer sentido. Para perguntas sobre
design/interface, considere a tela inteira. Para erros/código, priorize a
região do erro e o código relacionado. Para fotos, priorize descrição visual
geral. Para gráficos, preserve eixos, legenda, valores e tendências.

Retorne SOMENTE JSON válido, sem markdown:
{
  "image_type": "...",
  "confidence": 0.0,
  "visual_summary": "...",
  "ocr": "...",
  "key_data": ["..."],
  "regions": [
    {"name":"...", "reason":"...", "location":"top|bottom|left|right|center|unknown"}
  ],
  "relevant_for_question": ["..."],
  "uncertainties": ["..."]
}

Se não houver texto, use o campo ocr como string vazia.
Mantenha a resposta compacta, normalmente abaixo de 1200 tokens.
"""


async def analyze_images(
    *,
    images: list[dict[str, Any]],
    query: str,
    llm_client,
    model: str,
) -> str:
    prepared = prepare_many(images, query)
    if not prepared:
        return ""

    content: list[dict[str, Any]] = [
        {
            "type": "text",
            "text": (
                "Pergunta do usuário:\n"
                + query.strip()[:2000]
                + "\n\nAnalise as imagens anexadas para essa pergunta."
            ),
        }
    ]
    for p in prepared:
        content.append(
            {
                "type": "image_url",
                "image_url": {"url": f"data:{p.mime};base64,{p.data}"},
            }
        )

    try:
        result = await llm_client.chat_once(
            model=model,
            messages=[
                {"role": "system", "content": ANALYZER_SYSTEM},
                {"role": "user", "content": content},
            ],
            timeout=75.0,
            max_tokens=1400,
        )
        text = result.strip()
        try:
            analysis = json.loads(text)
            if not isinstance(analysis, dict):
                analysis = {"visual_summary": text}
        except json.JSONDecodeError:
            # Mesmo que o modelo escape do JSON, preservamos a leitura.
            analysis = {
                "image_type": "unknown",
                "confidence": 0.4,
                "visual_summary": text[:6000],
                "ocr": "",
                "key_data": [],
                "regions": [],
                "relevant_for_question": [],
                "uncertainties": ["Formato de saída do analisador não estruturado."],
            }
    except Exception as exc:
        logger.warning("image analyzer failed: %s", exc)
        # Fallback seguro: ainda permite que o fluxo atual de visão continue.
        return ""

    prepared_meta = [
        {
            "name": p.name,
            "dimensions": f"{p.width}x{p.height}" if p.width else "unknown",
            "optimization": p.mode,
            "original_bytes": p.original_bytes,
            "optimized_bytes": p.output_bytes,
        }
        for p in prepared
    ]
    return compact_visual_context(
        query=query,
        prepared=prepared_meta,
        analysis=analysis,
    )
