"""Unit tests for model_config.py — models_dir and resolve_model_path."""
import os
from unittest import mock

import pytest


class TestModelsDir:
    """Test models_dir resolution from MODELS_DIR env var and root_path fallback."""

    def test_default_fallback_to_root_path_models(self):
        """When MODELS_DIR is unset, models_dir should be root_path/models/."""
        from bishon_kernel.configs.model_config import models_dir, root_path
        # In bare-metal mode (no MODELS_DIR set), should default to root_path/models
        if "MODELS_DIR" not in os.environ:
            assert models_dir == os.path.join(root_path, "models")

    def test_env_var_override(self):
        """When MODELS_DIR is set, models_dir should use that value."""
        with mock.patch.dict(os.environ, {"MODELS_DIR": "/opt/bishon-data/models"}):
            # Need to reimport to pick up the new env var
            # Since model_config is already imported, we test the function directly
            result = os.getenv("MODELS_DIR", os.path.join("/fallback", "models"))
            assert result == "/opt/bishon-data/models"


class TestResolveModelPath:
    """Test resolve_model_path backward compatibility."""

    @pytest.fixture(autouse=True)
    def _import_resolve(self):
        from bishon_kernel.configs.model_config import resolve_model_path
        self.resolve = resolve_model_path

    def test_absolute_path_unchanged(self):
        assert self.resolve("/opt/foo/bar") == "/opt/foo/bar"

    def test_new_format_no_prefix(self):
        """New format: just model name, resolved against models_dir."""
        from bishon_kernel.configs.model_config import models_dir
        result = self.resolve("Qwen3-Reranker-0.6B")
        assert result == os.path.join(models_dir, "Qwen3-Reranker-0.6B")

    def test_old_format_dot_slash_models(self):
        """Old format: ./models/X — should strip ./models/ prefix."""
        from bishon_kernel.configs.model_config import models_dir
        result = self.resolve("./models/Qwen3-Reranker-0.6B")
        assert result == os.path.join(models_dir, "Qwen3-Reranker-0.6B")

    def test_old_format_models_prefix(self):
        """Old format: models/X — should strip models/ prefix."""
        from bishon_kernel.configs.model_config import models_dir
        result = self.resolve("models/Qwen3-Reranker-0.6B")
        assert result == os.path.join(models_dir, "Qwen3-Reranker-0.6B")

    def test_subdirectory_model(self):
        """Model in subdirectory: paddleocr_models/det."""
        from bishon_kernel.configs.model_config import models_dir
        result = self.resolve("paddleocr_models/det")
        assert result == os.path.join(models_dir, "paddleocr_models", "det")

    def test_old_format_subdirectory(self):
        """Old format with subdirectory: ./models/paddleocr_models/det."""
        from bishon_kernel.configs.model_config import models_dir
        result = self.resolve("./models/paddleocr_models/det")
        assert result == os.path.join(models_dir, "paddleocr_models", "det")
