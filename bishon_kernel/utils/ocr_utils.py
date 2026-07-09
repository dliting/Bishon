"""OCR-related utility functions."""
import base64

import numpy as np


def numpy_to_ocr_data(img_array: np.ndarray) -> dict:
    """Convert a numpy image array to the OCR engine input format (img64/height/width/channels)."""
    h, w = img_array.shape[:2]
    c = img_array.shape[2] if img_array.ndim == 3 else 1
    return {
        "img64":    base64.b64encode(img_array).decode("utf-8"),
        "height":   h,
        "width":    w,
        "channels": c,
    }


def ocr_data_to_numpy(img_data: dict) -> np.ndarray:
    """Convert the OCR engine input format back to a numpy array."""
    binary = base64.b64decode(img_data["img64"])
    img    = np.frombuffer(binary, dtype=np.uint8)
    return img.reshape((img_data["height"], img_data["width"], img_data["channels"]))
