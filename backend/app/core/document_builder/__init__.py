"""Document & Archive Builder — skill da Gama.

Cria, modifica, compacta e devolve arquivos (ZIP, PDF).
O LLM decide conteúdo/instruções; o backend executa de forma determinística.
"""

from .pipeline import (
    build_zip_from_project,
    build_zip_from_files,
    apply_edits_and_zip,
    build_pdf,
    get_artifact,
    list_artifacts,
)

__all__ = [
    "build_zip_from_project",
    "build_zip_from_files",
    "apply_edits_and_zip",
    "build_pdf",
    "get_artifact",
    "list_artifacts",
]
