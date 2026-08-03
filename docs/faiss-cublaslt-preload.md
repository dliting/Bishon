# FAISS GPU libcublasLt 符号解析问题

## 问题现象

在 CUDA 12.5+ 环境下 `import faiss` 时报错：

```
OSError: /path/to/nvidia/cublas/lib/libcublas.so.12: undefined symbol: cublasLtGetEnvironmentMode, version libcublasLt.so.12
```

FAISS GPU 版本（`faiss-gpu-cu12`）依赖 `libcublas.so.12`，而该库从 CUDA 12.5 起新增了对 `cublasLtGetEnvironmentMode` 符号的依赖。该符号定义在 `libcublasLt.so.12` 中，但动态链接器在加载 `libcublas.so.12` 时可能尚未加载 `libcublasLt.so.12`，导致符号解析失败。

## 根因分析

```
import faiss
  → faiss.loader._load_shared_library()
    → ctypes.CDLL("libfaiss.so", mode=RTLD_GLOBAL)
      → libfaiss.so 链接 libcublas.so.12
        → libcublas.so.12 需要 cublasLtGetEnvironmentMode（来自 libcublasLt.so.12）
          → libcublasLt.so.12 尚未加载 → undefined symbol
```

Python 的 `ctypes.CDLL` 不走标准 `ld` 链接路径，而是直接 `dlopen` 指定文件。这意味着 `libcublas.so.12` 的 `NEEDED` 条目（`libcublasLt.so.12`）只有在系统库搜索路径中才能自动解析。pip 安装的 `nvidia-cublas-cu12` 将库放在 Python 包目录下，不在系统路径中，因此自动解析失败。

## 环境复现

| 组件 | 版本 |
|------|------|
| OS | Ubuntu 22.04 (WSL2) |
| CUDA Driver | 12.6 (561.17) |
| Python | 3.11 |
| faiss-gpu-cu12 | 1.13.2 |
| nvidia-cublas-cu12 | 12.6.4.1 |
| nvidia-cuda-runtime-cu12 | 12.6.77 |

## 解决方案

在 `import faiss` 之前，显式预加载 `libcublasLt.so.12`，使用 `RTLD_GLOBAL` 使其符号对后续加载的库可见。

```python
import ctypes
import os

def preload_cublaslt():
    """Preload libcublasLt before faiss imports."""
    try:
        import nvidia.cublas.lib as cublas_dir
        cublaslt_path = os.path.join(
            os.path.dirname(cublas_dir.__file__),
            "libcublasLt.so.12"
        )
        if os.path.exists(cublaslt_path):
            ctypes.CDLL(cublaslt_path, mode=ctypes.RTLD_GLOBAL)
    except (ImportError, OSError) as e:
        logging.warning("libcublasLt preload skipped: %s", e)

preload_cublaslt()
import faiss  # 现在可以正常加载
```

## 项目中的实现

- **共享函数**：`bishon_kernel/utils/gpu_utils.py` 中的 `preload_cublaslt()`
- **调用点**：
  - `gpu_utils.py` 模块级别（import 时自动执行）
  - `bishon_kernel/connector/database/faiss/faiss_client.py` import faiss 之前

因为 `faiss_client.py` 已导入 `gpu_utils`（`from bishon_kernel.utils.gpu_utils import can_use_faiss_gpu`），`gpu_utils` 模块加载时已执行预加载，后续的 `import faiss` 自然安全。两处都调用是为了防御 `faiss_client.py` 被单独导入时绕过 `gpu_utils` 的情况。

## 验证方法

```bash
# 修复前（报错）
python -c "import faiss"
# → OSError: undefined symbol: cublasLtGetEnvironmentMode

# 修复后（正常）
python -c "from bishon_kernel.utils.gpu_utils import preload_cublaslt; preload_cublaslt(); import faiss; print('OK')"
# → OK
```

## 注意事项

- `RTLD_GLOBAL` 使符号对整个进程可见，可能影响后续加载的其他库。在本项目中不影响，因为 cublasLt 是 NVIDIA 标准库。
- 如果未来升级到 CUDA 13，`libcublasLt.so.13` 的路径需要相应调整。`nvidia.cublas.lib` 包目录名可能变化，建议在升级后验证。
- 此方案不需要修改 faiss-gpu 版本或下载新的 CUDA 包，零额外流量。
