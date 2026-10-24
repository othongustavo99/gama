"""Identifica intenção de programação sem confundir o modo Trabalhar com um projeto.

O modo selecionado determina o modelo e a profundidade. O assunto atual,
com continuidade explícita para turnos curtos, determina se regras de código
ou contexto de repositório realmente devem entrar no prompt.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Sequence

# Termos de engenharia. Excluímos 'analisar', 'trabalhar' e 'projeto' isolados:
# é perfeitamente válido analisar um filme ou falar de um projeto de vida.
_CODE_TOPIC = re.compile(
    r"(?i)(?:\b(?:flutter|dart|python|javascript|typescript|fastapi|node\.?js|"
    r"react|kotlin|swift|gradle|backend|frontend|api|sql|github|"
    r"reposit[oó]rio|debug|bug|deploy|c[oó]digo|codificar|programa[cç][aã]o|"
    r"programar|compila[cç][aã]o|refatora[cç][aã]o|script|widget|endpoint|"
    r"pull\s+request|commit|terminal|stack\s*trace|exception)\b|"
    r"\b(?:app|aplicativo|software|site|sistema|banco\s+de\s+dados)\b|"
    r"\b(?:lib|src|backend|test|tests|android|ios)/[\w./-]+|"
    r"\b[\w./-]+\.(?:dart|py|js|ts|tsx|jsx|kt|swift|java|go|rs)\b|"
    r"```[\s\S]*?```|\[(?:project_id|need_more):)",
)
_PROJECT_REFERENCE = re.compile(
    r"(?i)\b(?:"
    r"(?:esse|este|aquele|meu|o|no|do|nesse|neste)\s+(?:projeto|repo|reposit[oó]rio|c[oó]digo|arquivo)|"
    r"(?:esse|este|aquele|meu|o|no|do|nesse|neste)\s+(?:app|aplicativo|software)|"
    r"(?:os|esses|estes)\s+arquivos|arquivos?\s+(?:do\s+)?(?:app|projeto)|"
    r"(?:corrija|corrige|ajuste|altere|refatore|implemente|revise|analise)\s+"
    r"(?:o|esse|este|no|meu|nesse|neste)\s+(?:projeto|c[oó]digo|arquivo|app)|"
    r"(?:no|nesse|este)\s+zip"
    r")\b",
)
_RELATIVE_CONTINUATION = re.compile(
    r"(?i)^\s*(?:sim|n[aã]o|ok|pode|pode\s+ser|manda|faz|fa[cç]a|"
    r"continue|continua|prossiga|segue|isso|essa|esse|perfeito|beleza|"
    r"e\s+depois|e\s+agora|pr[oó]xima\s+etapa|pr[oó]xima\s+fase|"
    r"e\s+o\s+pr[oó]ximo\s+passo)\s*[.!?]*\s*$"
)
_NON_CODE_PROJECT = re.compile(
    r"(?i)\bprojeto\s+(?:de\s+)?(?:vida|viagem|f[eé]rias|social|escolar|"
    r"comunit[aá]rio|pessoal|pesquisa\s+acad[eê]mica|constru[cç][aã]o)\b"
)


@dataclass(frozen=True)
class WorkIntent:
    code_task: bool
    project_context: bool


def _message_text(message: dict[str, Any]) -> str:
    content = message.get("content") or ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(str(piece.get("text") or "") for piece in content if isinstance(piece, dict))
    return ""


def _previous_topic(messages: Sequence[dict[str, Any]] | None, current: str) -> str:
    """Segue confirmações curtas, mas para na primeira mudança de assunto."""
    if not messages:
        return ""
    skipped_current = False
    for message in reversed(messages[-16:]):
        if message.get("role") != "user":
            continue
        text = _message_text(message).strip()
        if not text:
            continue
        # O histórico normalmente inclui o turno atual; remover só a última cópia.
        if not skipped_current and text == current.strip():
            skipped_current = True
            continue
        if _RELATIVE_CONTINUATION.fullmatch(text):
            continue
        return text
    return ""


def detect_work_intent(
    last_user: str,
    *,
    messages: Sequence[dict[str, Any]] | None = None,
    has_active_project: bool = False,
) -> WorkIntent:
    """Determina se o turno exige programação e/ou o contexto de um projeto.

    Não depende do modelo nem do nome da aba. Não consome tokens extras.
    """
    current = (last_user or "").strip()
    if not current:
        return WorkIntent(False, False)

    is_followup = bool(_RELATIVE_CONTINUATION.fullmatch(current))
    topic = _previous_topic(messages, current) if is_followup else current
    if not topic:
        topic = current

    # Marcadores de anexos têm precedência, ainda que o briefing seja curto.
    has_project_marker = bool(re.search(r"\[(?:project_id|need_more):", current, re.I))
    explicit_repo = bool(re.search(r"(?i)(?:https?://)?(?:www\.)?github\.com/\S+", current))
    code_task = bool(_CODE_TOPIC.search(topic)) or has_project_marker or explicit_repo
    project_ref = bool(_PROJECT_REFERENCE.search(topic))
    if has_active_project and re.search(
        r"(?i)\b[\w./-]+\.(?:dart|py|js|ts|tsx|jsx|kt|swift|java|go|rs)\b|"
        r"\b(?:esse|este|aquele|o|meu)\s+(?:bug|erro|endpoint|widget|m[oó]dulo|fun[cç][aã]o)\b",
        topic,
    ):
        project_ref = True

    if _NON_CODE_PROJECT.search(topic) and not (_CODE_TOPIC.search(topic)):
        project_ref = False

    # Um projeto antigo só é recuperado quando o usuário se refere a ele.
    project_context = bool(
        has_project_marker or explicit_repo or (has_active_project and project_ref)
    )
    # Uma referência inequívoca a um projeto carregado também é tarefa técnica,
    # mesmo que o usuário não mencione a linguagem nem o tipo de código.
    if project_context:
        code_task = True
    return WorkIntent(code_task=code_task, project_context=project_context)
