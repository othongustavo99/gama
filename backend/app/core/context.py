from typing import Awaitable, Callable, List, Dict, Optional


SummarizeFn = Callable[[List[Dict[str, str]]], Awaitable[str]]


class ContextManager:
    """
    Prepara o contexto enviado ao modelo.

    - Cabe no limite → envia tudo
    - Passa do limite → resume o início (pelo modelo, se disponível)
      e mantém as mensagens mais recentes
    """

    def __init__(self, max_messages: int = 48, summary_max_chars: int = 3500):
        self.max_messages = max_messages
        self.summary_max_chars = summary_max_chars

    async def prepare(
        self,
        messages: List[Dict[str, str]],
        *,
        summarize: Optional[SummarizeFn] = None,
    ) -> List[Dict[str, str]]:
        if not messages:
            return []

        normalized = [
            {
                "role": m.get("role", "user"),
                "content": (m.get("content") or "").strip(),
            }
            for m in messages
            if (m.get("content") or "").strip()
        ]

        if len(normalized) <= self.max_messages:
            return normalized

        keep = max(self.max_messages - 2, 24)
        older = normalized[:-keep]
        recent = normalized[-keep:]

        summary = ""
        if summarize is not None:
            try:
                summary = await summarize(older)
            except Exception:
                summary = ""

        if not summary:
            summary = self._summarize_locally(older)

        if not summary:
            return recent

        if len(summary) > self.summary_max_chars:
            summary = summary[: self.summary_max_chars] + "…"

        summary_message = {
            "role": "user",
            "content": (
                "[Resumo do início desta conversa — use como contexto, "
                "não como mensagem nova do usuário]\n"
                f"{summary}"
            ),
        }
        return [summary_message, *recent]

    def _summarize_locally(self, messages: List[Dict[str, str]]) -> str:
        parts: List[str] = []
        total = 0
        for m in messages:
            role = m["role"]
            content = m["content"].replace("\n", " ").strip()
            if not content:
                continue
            snippet = content[:120] + ("…" if len(content) > 120 else "")
            label = "Usuário" if role == "user" else "Gamma"
            line = f"{label}: {snippet}"
            if total + len(line) > self.summary_max_chars:
                break
            parts.append(line)
            total += len(line) + 1
        return "\n".join(parts)
