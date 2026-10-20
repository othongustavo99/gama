from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
os.environ.setdefault("DATA_DIR", tempfile.mkdtemp())

import _httpx_stub  # noqa: F401,E402
from pypdf import PdfWriter  # noqa: E402

from app.core.code_analyzer import pdf_reader  # noqa: E402


def blank_pdf(page_count=1):
    writer = PdfWriter()
    for _ in range(page_count):
        writer.add_blank_page(width=612, height=792)
    buffer = io.BytesIO()
    writer.write(buffer)
    return buffer.getvalue()


class FakeOCRDocument:
    def close(self):
        pass


class PDFReaderTests(unittest.TestCase):
    def test_scanned_page_uses_ocr_and_reports_page_metadata(self):
        with (
            patch.object(pdf_reader, "_open_ocr_document", return_value=(FakeOCRDocument(), "ready")),
            patch.object(pdf_reader, "_ocr_page", return_value="def hello():\n    return 'world'"),
        ):
            pages, stats = pdf_reader.extract_pages_detailed(blank_pdf())

        self.assertEqual(len(pages), 1)
        self.assertEqual(pages[0]["page"], 1)
        self.assertEqual(pages[0]["extraction_method"], "ocr")
        self.assertIn("def hello", pages[0]["text"])
        self.assertEqual(stats["ocr_pages"], 1)
        self.assertEqual(stats["ocr_status"], "completed")

    def test_missing_ocr_keeps_native_text_behavior_and_reports_unreadable_scan(self):
        with patch.object(pdf_reader, "_open_ocr_document", return_value=(None, "pymupdf_unavailable")):
            pages, stats = pdf_reader.extract_pages_detailed(blank_pdf())

        self.assertEqual(pages, [])
        self.assertEqual(stats["scanned_pages"], 1)
        self.assertEqual(stats["ocr_skipped_pages"], 1)
        self.assertEqual(stats["unreadable_pages"], 1)
        self.assertEqual(stats["ocr_status"], "pymupdf_unavailable")

    def test_ocr_attempt_limit_is_visible(self):
        with (
            patch.object(pdf_reader, "MAX_OCR_PAGES", 1),
            patch.object(pdf_reader, "_open_ocr_document", return_value=(FakeOCRDocument(), "ready")),
            patch.object(pdf_reader, "_ocr_page", return_value="recognized words"),
        ):
            pages, stats = pdf_reader.extract_pages_detailed(blank_pdf(2))

        self.assertEqual([page["page"] for page in pages], [1])
        self.assertEqual(stats["ocr_pages"], 1)
        self.assertEqual(stats["ocr_skipped_pages"], 1)
        self.assertEqual(stats["ocr_status"], "partial")

    def test_ocr_with_no_recognized_text_is_reported_as_failed(self):
        with (
            patch.object(pdf_reader, "_open_ocr_document", return_value=(FakeOCRDocument(), "ready")),
            patch.object(pdf_reader, "_ocr_page", return_value=""),
        ):
            pages, stats = pdf_reader.extract_pages_detailed(blank_pdf())

        self.assertEqual(pages, [])
        self.assertEqual(stats["ocr_failed_pages"], 1)
        self.assertEqual(stats["ocr_status"], "failed")


if __name__ == "__main__":
    unittest.main()
