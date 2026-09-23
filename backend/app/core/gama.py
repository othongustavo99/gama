from typing import List, Dict

from .context import ContextManager
from .prompts import build_system_prompt


class GamaCore:
    """
    Núcleo central da Gama.

    Responsável por:
    - personalidade
    - prompt
    - contexto
    - preparação da conversa
    """

    def __init__(self, max_context_messages: int = 30):
        self.context_manager = ContextManager(
            max_messages=max_context_messages
        )

    def build_messages(
        self,
        messages: List[Dict[str, str]],
    ) -> List[Dict[str, str]]:
        """
        Prepara as mensagens que serão enviadas ao modelo.
        """

        system_prompt = build_system_prompt()

        context = self.context_manager.prepare(messages)

        return [
            {
                "role": "system",
                "content": system_prompt,
            },
            *context,
        ]