"""Defensive checks for image_loader and pdf_loader when ocr_engine=None."""
import pytest


class TestImageLoaderOcrGuard:
    """UnstructuredPaddleImageLoader must raise ValueError when ocr_engine=None."""

    def test_raises_when_ocr_none(self, tmp_path):
        from bishon_kernel.utils.loader.image_loader import UnstructuredPaddleImageLoader
        img_file = tmp_path / "test.png"
        img_file.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 100)
        with pytest.raises(ValueError, match="OCR"):
            UnstructuredPaddleImageLoader(str(img_file), ocr_engine=None, mode="elements")


class TestPdfLoaderOcrGuard:
    """UnstructuredPaddlePDFLoader must raise ValueError when ocr_engine=None."""

    def test_raises_when_ocr_none(self, tmp_path):
        from bishon_kernel.utils.loader.pdf_loader import UnstructuredPaddlePDFLoader
        pdf_file = tmp_path / "test.pdf"
        pdf_file.write_bytes(b"%PDF-1.4" + b"\x00" * 100)
        with pytest.raises(ValueError, match="OCR"):
            UnstructuredPaddlePDFLoader(str(pdf_file), ocr_engine=None, mode="elements")
