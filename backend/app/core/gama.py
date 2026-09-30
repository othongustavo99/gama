from typing import List, Dict, Optional, Tuple

from .context import ContextManager
from .memory import memory_store, try_extract_memory
from .prompts import build_system_prompt


class GamaCore:
    """
    Núcleo central da Gamma.
    """

    def __init__(self, max_context_messages: int = 24):
        self.context_manager = ContextManager(
            max_messages=max_context_messages
        )

    async def build_messages(
        self,
        messages: List[Dict[str, str]],
        *,
        model: str,
        ollama_client,
        auto_memory: bool = True,
    ) -> Tuple[List[Dict[str, str]], Optional[str]]:
        """
        Retorna (messages_for_model, fact_saved_or_none).
        """
        fact_saved: Optional[str] = None

        if auto_memory and messages:
            last = messages[-1]
            if last.get("role") == "user":
                extracted = try_extract_memory(last.get("content") or "")
                if extracted:
                    try:
                        memory_store.add_fact(extracted, source="auto")
                        fact_saved = extracted
                    except Exception:
                        fact_saved = None

        memory_block = memory_store.as_prompt_block()
        system_prompt = build_system_prompt(memory_block=memory_block)

        async def _summarize(older: List[Dict[str, str]]) -> str:
            # Limita o que manda para o resumo (custo/latência)
            sample = older[-20:] if len(older) > 20 else older
            transcript_lines = []
            for m in sample:
                role = "Usuário" if m.get("role") == "user" else "Gamma"
                text = (m.get("content") or "").replace("\n", " ")
                if len(text) > 200:
                    text = text[:200] + "…"
                transcript_lines.append(f"{role}: {text}")
            transcript = "\n".join(transcript_lines)

            prompt = (
                "Resuma em português, em no máximo 8 frases curtas, "
                "os pontos importantes desta conversa. "
                "Foque em decisões, fatos, preferências e tarefas. "
                "Não invente nada.\n\n"
                f"{transcript}"
            )
            return await ollama_client.chat_once(
                model=model,
                messages=[{"role": "user", "content": prompt}],
                timeout=90.0,
            )

        context = await self.context_manager.prepare(
            messages,
            summarize=_summarize,
        )

        prepared = [
            {"role": "system", "content": system_prompt},
            *context,
        ]
        return prepared, fact_saved
