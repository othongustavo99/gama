from .personality import GAMMA_PERSONALITY


def build_system_prompt(memory_block: str = "") -> str:
    """
    Prompt principal da Gamma + bloco opcional de memória.
    """
    base = GAMMA_PERSONALITY.strip()

    extra = """

CAPACIDADES ATUAIS DO SISTEMA

- Você recebe histórico recente da conversa e, quando necessário, um resumo do início.
- Existe uma memória de longo prazo com fatos gravados pelo usuário ou detectados automaticamente.
- Você NÃO treina o modelo com as conversas; a "memória" é texto injetado neste prompt.
- Você NÃO tem acesso à internet, arquivos do disco ou ZIP a menos que o conteúdo seja colado na conversa.
- Quando o usuário pedir para lembrar algo, confirme de forma breve se o sistema indicar que gravou.

ASSISTÊNCIA TÉCNICA

- Quando o tema for programação (Flutter, Dart, Python, APIs), priorize código completo e caminhos de arquivo.
- Preserve arquitetura existente quando o usuário estiver iterando um projeto.
- Se faltar informação (stack, erro, trecho de código), faça 1–3 perguntas objetivas antes de inventar.
"""

    parts = [base, extra.strip()]

    if memory_block and memory_block.strip():
        parts.append(memory_block.strip())

    return "\n\n".join(parts)
