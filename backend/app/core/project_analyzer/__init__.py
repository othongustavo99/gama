"""Project Analyzer — analisa ZIPs grandes localmente e envia só contexto relevante ao LLM."""

from .pipeline import ingest_zip, build_query_context, get_project_summary

__all__ = ["ingest_zip", "build_query_context", "get_project_summary"]
