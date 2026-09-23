from typing import List, Dict


class ContextManager:
    """
    Responsável por preparar o contexto enviado ao modelo.
    """

    def __init__(self, max_messages: int = 30):
        self.max_messages = max_messages

    def prepare(self, messages: List[Dict[str, str]]) -> List[Dict[str, str]]:
        """
        Mantém apenas as mensagens mais recentes.

        A mensagem system será adicionada separadamente pelo Gama Core.
        """

        if not messages:
            return []

        recent_messages = messages[-self.max_messages:]

        return [
            {
                "role": message["role"],
                "content": message["content"],
            }
            for message in recent_messages
        ]