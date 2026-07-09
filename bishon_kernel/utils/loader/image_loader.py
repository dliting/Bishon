"""Loader that loads image files via PaddleOCR."""
import os
from collections.abc import Callable
from typing import Any

import cv2
from langchain_core.document_loaders import BaseLoader
from langchain_core.documents import Document

from bishon_kernel.utils.ocr_utils import numpy_to_ocr_data

OCR_UNAVAILABLE_MSG = "OCR engine not available, cannot process image files. Please check PaddleOCR installation."


class UnstructuredPaddleImageLoader(BaseLoader):
    """Loader that uses PaddleOCR to extract text from image files."""

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
        img_np = cv2.imread(self.file_path)
        if img_np is None:
            raise ValueError(f"Cannot read image file: {self.file_path}")

        img_data   = numpy_to_ocr_data(img_np)
        ocr_result = self.ocr_engine(img_data)

        if not ocr_result:
            return []

        text = "\n".join(ocr_result)
        metadata = {
            "filename": os.path.basename(self.file_path),
            "filetype": "text/plain",
        }
        return [Document(page_content=text, metadata=metadata)]
