"""Tests for gpu_utils.preload_cublaslt — namespace package compatibility."""
import sys
import types
from unittest.mock import patch


class TestPreloadCublaslt:
    """Verify preload_cublaslt handles both regular and namespace packages."""

    def test_regular_package_with_file(self, tmp_path):
        """When __file__ is set (regular package), __path__ still works."""
        lib_dir = tmp_path / "nvidia" / "cublas" / "lib"
        lib_dir.mkdir(parents=True)
        (lib_dir / "libcublasLt.so.12").write_bytes(b"\x00")

        cublas_lib = types.ModuleType("nvidia.cublas.lib")
        cublas_lib.__file__ = str(lib_dir / "__init__.py")
        cublas_lib.__path__ = [str(lib_dir)]

        with patch.dict(sys.modules, {"nvidia.cublas.lib": cublas_lib}):
            # Re-import to exercise the function
            from bishon_kernel.utils.gpu_utils import preload_cublaslt

            # Should not raise — __path__[0] gives the same dir as dirname(__file__)
            preload_cublaslt()

    def test_namespace_package_file_is_none(self, tmp_path):
        """When __file__ is None (namespace package), __path__ is used instead."""
        lib_dir = tmp_path / "nvidia" / "cublas" / "lib"
        lib_dir.mkdir(parents=True)
        (lib_dir / "libcublasLt.so.12").write_bytes(b"\x00")

        cublas_lib = types.ModuleType("nvidia.cublas.lib")
        cublas_lib.__file__ = None  # namespace package
        cublas_lib.__path__ = [str(lib_dir)]

        with patch.dict(sys.modules, {"nvidia.cublas.lib": cublas_lib}):
            from bishon_kernel.utils.gpu_utils import preload_cublaslt

            # Must not raise TypeError
            preload_cublaslt()

    def test_import_error_handled(self):
        """If nvidia.cublas.lib is not installed, log warning and continue."""
        with patch.dict(sys.modules, {}, clear=False):
            # Remove the module if present to force ImportError
            sys.modules.pop("nvidia.cublas.lib", None)
            sys.modules.pop("nvidia.cublas", None)
            sys.modules.pop("nvidia", None)

            from bishon_kernel.utils.gpu_utils import preload_cublaslt

            # Should not raise
            preload_cublaslt()

    def test_empty_path_handled(self):
        """If __path__ is empty, IndexError is caught gracefully."""
        cublas_lib = types.ModuleType("nvidia.cublas.lib")
        cublas_lib.__file__ = None
        cublas_lib.__path__ = []  # empty

        with patch.dict(sys.modules, {"nvidia.cublas.lib": cublas_lib}):
            from bishon_kernel.utils.gpu_utils import preload_cublaslt

            # Should not raise IndexError
            preload_cublaslt()
