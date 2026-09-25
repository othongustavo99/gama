from .personality import GAMMA_PERSONALITY


def build_system_prompt() -> str:
    """
    Constrói o prompt principal da Gamma.
    """

    return GAMMA_PERSONALITY.strip()