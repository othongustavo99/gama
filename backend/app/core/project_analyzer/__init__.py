"""Project Analyzer — compat layer.

A implementação real evoluiu para Code Analyzer.
Este pacote reexporta a API antiga para não quebrar rotas e imports existentes.
"""

from ..code_analyzer import (
    build_query_context,
    get_project_summary,
    ingest_zip,
)

__all__ = ["ingest_zip", "build_query_context", "get_project_summary"]
