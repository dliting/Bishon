"""Loader that loads PDF files via PaddleOCR."""
import os
from collections.abc import Callable
from typing import Any

import fitz
import numpy as np
from langchain_core.document_loaders import BaseLoader
from langchain_core.documents import Document
from tqdm import tqdm

from bishon_kernel.utils.ocr_utils import numpy_to_ocr_data

OCR_UNAVAILABLE_MSG = "OCR engine not available, cannot process PDF files. Please check PaddleOCR installation."


class UnstructuredPaddlePDFLoader(BaseLoader):
    """Loader that uses PaddleOCR to extract text from PDF files."""

    def __init__(
        self,
        file_path: str | list[str],
        ocr_engine: Callable | None,
        mode: str = "single",
        **unstructured_kwargs: Any,
    ):
        if not callable(ocr_engine):
            raise ValueError(OCR_UNAVAILABLE_MSG)
        self.file_path  = file_path if isinstance(file_path, str) else file_path[0]
        self.ocr_engine = ocr_engine

    def load(self) -> list[Document]:
        doc = fitz.open(self.file_path)
        try:
            all_text_parts = []

            for page_idx in tqdm(range(doc.page_count)):
                page = doc.load_page(page_idx)
                pix  = page.get_pixmap()
                img  = np.frombuffer(pix.samples, dtype=np.uint8).reshape((pix.h, pix.w, pix.n))

                img_data   = numpy_to_ocr_data(img)
                ocr_result = self.ocr_engine(img_data)
                if ocr_result:
                    all_text_parts.append(f"--- Page {page_idx + 1} ---\n" + "\n".join(ocr_result))

            if not all_text_parts:
                return []

            text     = "\n\n".join(all_text_parts)
            metadata = {
                "filename": os.path.basename(self.file_path),
                "filetype": "application/pdf",
                "page_count": doc.page_count,
            }
            return [Document(page_content=text, metadata=metadata)]
        finally:
            doc.close()
