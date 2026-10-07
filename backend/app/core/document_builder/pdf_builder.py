"""PDF Builder — gera PDFs profissionais a partir de seções estruturadas.

O LLM define título, seções, código, tabelas; o backend renderiza.
Usa reportlab quando disponível; fallback mínimo com pypdf não cobre layout,
então reportlab é obrigatório para geração.
"""

from __future__ import annotations

import io
import logging
from typing import Any, Optional

from .validator import validate_pdf

logger = logging.getLogger(__name__)


def _require_reportlab():
    try:
        from reportlab.lib.pagesizes import A4
        from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
        from reportlab.lib.units import cm, mm
        from reportlab.lib import colors
        from reportlab.platypus import (
            SimpleDocTemplate,
            Paragraph,
            Spacer,
            Preformatted,
            Table,
            TableStyle,
            PageBreak,
            KeepTogether,
            ListFlowable,
            ListItem,
            Image,
            HRFlowable,
        )
        from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_JUSTIFY
        return {
            "A4": A4,
            "ParagraphStyle": ParagraphStyle,
            "getSampleStyleSheet": getSampleStyleSheet,
            "cm": cm,
            "mm": mm,
            "colors": colors,
            "SimpleDocTemplate": SimpleDocTemplate,
            "Paragraph": Paragraph,
            "Spacer": Spacer,
            "Preformatted": Preformatted,
            "Table": Table,
            "TableStyle": TableStyle,
            "PageBreak": PageBreak,
            "KeepTogether": KeepTogether,
            "ListFlowable": ListFlowable,
            "ListItem": ListItem,
            "Image": Image,
            "HRFlowable": HRFlowable,
            "TA_CENTER": TA_CENTER,
            "TA_LEFT": TA_LEFT,
            "TA_JUSTIFY": TA_JUSTIFY,
        }
    except ImportError as e:
        raise RuntimeError(
            "reportlab não instalado. Adicione reportlab ao requirements.txt "
            "e rode pip install reportlab"
        ) from e


def _escape(text: str) -> str:
    return (
        (text or "")
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def build_pdf(
    *,
    title: str = "Documento",
    subtitle: str = "",
    author: str = "Gama",
    sections: list[dict[str, Any]] | None = None,
    header: str = "",
    footer: str = "Gama · Document & Archive Builder",
    page_numbers: bool = True,
) -> bytes:
    """Gera PDF a partir de seções.

    section types:
      heading   {level: 1-3, text}
      paragraph {text}
      code      {text, language?}
      table     {headers: [], rows: [[]]}
      list      {items: [], ordered?: bool}
      image     {path or data_base64, width?}
      pagebreak {}
      spacer    {height?}
      hr        {}
    """
    rl = _require_reportlab()
    buf = io.BytesIO()

    def _header_footer(canvas, doc):
        canvas.saveState()
        if header:
            canvas.setFont("Helvetica", 8)
            canvas.setFillColor(rl["colors"].grey)
            canvas.drawString(2 * rl["cm"], A4_H - 1.2 * rl["cm"], header[:80])
        if footer or page_numbers:
            canvas.setFont("Helvetica", 8)
            canvas.setFillColor(rl["colors"].grey)
            foot = footer or ""
            if page_numbers:
                foot = f"{foot}  ·  {doc.page}".strip(" ·")
            canvas.drawCentredString(A4_W / 2, 1.2 * rl["cm"], foot[:100])
        canvas.restoreState()

    A4_W, A4_H = rl["A4"]
    doc = rl["SimpleDocTemplate"](
        buf,
        pagesize=rl["A4"],
        leftMargin=2 * rl["cm"],
        rightMargin=2 * rl["cm"],
        topMargin=2 * rl["cm"],
        bottomMargin=2 * rl["cm"],
        title=title,
        author=author,
    )

    styles = rl["getSampleStyleSheet"]()
    styles.add(
        rl["ParagraphStyle"](
            name="DocTitle",
            parent=styles["Title"],
            fontSize=20,
            spaceAfter=8,
            alignment=rl["TA_CENTER"],
            textColor=rl["colors"].HexColor("#1a1a2e"),
        )
    )
    styles.add(
        rl["ParagraphStyle"](
            name="DocSubtitle",
            parent=styles["Normal"],
            fontSize=11,
            spaceAfter=16,
            alignment=rl["TA_CENTER"],
            textColor=rl["colors"].HexColor("#555555"),
        )
    )
    styles.add(
        rl["ParagraphStyle"](
            name="H1Custom",
            parent=styles["Heading1"],
            fontSize=14,
            spaceBefore=14,
            spaceAfter=6,
            textColor=rl["colors"].HexColor("#16213e"),
        )
    )
    styles.add(
        rl["ParagraphStyle"](
            name="H2Custom",
            parent=styles["Heading2"],
            fontSize=12,
            spaceBefore=10,
            spaceAfter=4,
            textColor=rl["colors"].HexColor("#0f3460"),
        )
    )
    styles.add(
        rl["ParagraphStyle"](
            name="H3Custom",
            parent=styles["Heading3"],
            fontSize=11,
            spaceBefore=8,
            spaceAfter=3,
        )
    )
    styles.add(
        rl["ParagraphStyle"](
            name="BodyCustom",
            parent=styles["Normal"],
            fontSize=10,
            leading=14,
            alignment=rl["TA_JUSTIFY"],
            spaceAfter=6,
        )
    )
    styles.add(
        rl["ParagraphStyle"](
            name="CodeCustom",
            parent=styles["Code"],
            fontSize=8,
            leading=11,
            fontName="Courier",
            backColor=rl["colors"].HexColor("#f5f5f5"),
            spaceBefore=4,
            spaceAfter=8,
            leftIndent=4,
            rightIndent=4,
        )
    )

    story: list[Any] = []
    story.append(rl["Paragraph"](_escape(title), styles["DocTitle"]))
    if subtitle:
        story.append(rl["Paragraph"](_escape(subtitle), styles["DocSubtitle"]))
    story.append(
        rl["HRFlowable"](
            width="100%",
            thickness=1,
            color=rl["colors"].HexColor("#e0e0e0"),
            spaceAfter=12,
        )
    )

    for sec in sections or []:
        stype = (sec.get("type") or "paragraph").lower()

        if stype == "pagebreak":
            story.append(rl["PageBreak"]())
            continue

        if stype == "spacer":
            h = float(sec.get("height") or 12)
            story.append(rl["Spacer"](1, h))
            continue

        if stype == "hr":
            story.append(
                rl["HRFlowable"](
                    width="100%",
                    thickness=0.5,
                    color=rl["colors"].HexColor("#cccccc"),
                    spaceBefore=6,
                    spaceAfter=6,
                )
            )
            continue

        if stype == "heading":
            level = int(sec.get("level") or 1)
            text = _escape(str(sec.get("text") or ""))
            style = {1: "H1Custom", 2: "H2Custom", 3: "H3Custom"}.get(level, "H2Custom")
            story.append(rl["Paragraph"](text, styles[style]))
            continue

        if stype == "paragraph":
            text = _escape(str(sec.get("text") or "")).replace("\n", "<br/>")
            story.append(rl["Paragraph"](text, styles["BodyCustom"]))
            continue

        if stype == "code":
            code = str(sec.get("text") or sec.get("code") or "")
            # limita linhas enormes
            lines = code.splitlines()
            if len(lines) > 200:
                code = "\n".join(lines[:200]) + "\n…[código truncado]"
            lang = sec.get("language") or ""
            if lang:
                story.append(
                    rl["Paragraph"](
                        f"<font size='8' color='#666666'>{_escape(lang)}</font>",
                        styles["BodyCustom"],
                    )
                )
            story.append(rl["Preformatted"](code, styles["CodeCustom"]))
            continue

        if stype == "table":
            headers = sec.get("headers") or []
            rows = sec.get("rows") or []
            data = []
            if headers:
                data.append([_escape(str(h)) for h in headers])
            for row in rows:
                data.append([_escape(str(c)) for c in row])
            if not data:
                continue
            # Paragraphs inside cells for wrapping
            para_data = [
                [rl["Paragraph"](cell, styles["BodyCustom"]) for cell in row]
                for row in data
            ]
            t = rl["Table"](para_data, repeatRows=1 if headers else 0)
            style_cmds = [
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold") if headers else ("FONTNAME", (0, 0), (-1, -1), "Helvetica"),
                ("FONTSIZE", (0, 0), (-1, -1), 9),
                ("BACKGROUND", (0, 0), (-1, 0), rl["colors"].HexColor("#eef2ff")) if headers else ("BACKGROUND", (0, 0), (-1, 0), rl["colors"].white),
                ("GRID", (0, 0), (-1, -1), 0.4, rl["colors"].HexColor("#cccccc")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 4),
                ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]
            t.setStyle(rl["TableStyle"](style_cmds))
            story.append(t)
            story.append(rl["Spacer"](1, 8))
            continue

        if stype == "list":
            items = sec.get("items") or []
            ordered = bool(sec.get("ordered"))
            flow_items = []
            for it in items:
                flow_items.append(
                    rl["ListItem"](
                        rl["Paragraph"](_escape(str(it)), styles["BodyCustom"]),
                        leftIndent=12,
                    )
                )
            if flow_items:
                story.append(
                    rl["ListFlowable"](
                        flow_items,
                        bulletType="1" if ordered else "bullet",
                        start=1,
                    )
                )
            continue

        if stype == "image":
            # path local ou bytes base64
            img_path = sec.get("path")
            width = float(sec.get("width") or 12) * rl["cm"]
            try:
                if img_path:
                    story.append(rl["Image"](img_path, width=width, height=width * 0.6, kind="proportional"))
                elif sec.get("data_base64"):
                    import base64
                    from reportlab.lib.utils import ImageReader

                    raw = base64.b64decode(sec["data_base64"])
                    story.append(
                        rl["Image"](
                            ImageReader(io.BytesIO(raw)),
                            width=width,
                            height=width * 0.6,
                            kind="proportional",
                        )
                    )
            except Exception as e:
                logger.warning("image skip: %s", e)
                story.append(
                    rl["Paragraph"](
                        f"<i>[imagem não incluída: {e}]</i>", styles["BodyCustom"]
                    )
                )
            continue

        # fallback: treat as paragraph
        text = _escape(str(sec.get("text") or ""))
        if text:
            story.append(rl["Paragraph"](text, styles["BodyCustom"]))

    doc.build(story, onFirstPage=_header_footer, onLaterPages=_header_footer)
    data = buf.getvalue()
    result = validate_pdf(data)
    if not result["ok"]:
        raise ValueError(f"PDF gerado inválido: {result['errors']}")
    return data
