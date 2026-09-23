from .personality import GAMA_PERSONALITY


def build_system_prompt() -> str:
    """
    Constrói o prompt principal da Gama.
    """

    return GAMA_PERSONALITY.strip()