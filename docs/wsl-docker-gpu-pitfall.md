# WSL2 + Docker GPU 踩坑：torch Error 500 "named symbol not found"

> **TL;DR** — 在 WSL2 上跑 `docker run --gpus all` 的容器，`nvidia-smi` 正常但
> `torch.cuda.is_available()` 返回 `False`，`cuInit(0)` 直接返回错误码 500
> (`CUDA_ERROR_SYMBOL_NOT_FOUND`，文本 "named symbol not found")。根因是
> **`nvidia-container-runtime` 在 cherry-pick WSL 驱动文件时漏掉了
> `libnvdxgdmal.so.1`**，而 `libcuda.so.1` 代理需要这个库才能跟 `/dev/dxg`
> 通信。修复：`-v /usr/lib/wsl:/usr/lib/wsl:ro`。

---

## 症状

| 检查 | 结果 |
|---|---|
| `nvidia-smi`（容器内） | ✓ 显示 GPU、driver 561.17、CUDA 12.6 |
| `ctypes.CDLL("libcuda.so.1")` | ✓ 加载成功 |
| `cuInit(0)` | ✗ 返回 500 (`CUDA_ERROR_SYMBOL_NOT_FOUND`) |
| `torch.cuda.is_available()` | ✗ `False`（warning: "Error 500: named symbol not found"） |
| `paddle.device.is_compiled_with_cuda()` / `get_device()` | ✗ 同样失败 |
| 同样的 conda env 在 WSL 宿主直接跑（不走 docker） | ✓ 正常 |

环境：
- Windows 11 + WSL2 Ubuntu-22.04
- Windows NVIDIA 驱动 561.17（含 WSL CUDA 12.6 支持）
- `nvidia/cuda:12.6.3-runtime-ubuntu22.04` 基础镜像
- 容器内 conda env: `torch==2.12.0+cu126`、`paddlepaddle-gpu==3.3.1`
- `nvidia-container-toolkit` 已装，`docker info | grep runtime` 可见 `nvidia`

---

## 排查：被排除的假设

| 假设 | 结论 |
|---|---|
| 容器基础镜像 CUDA 版本太老（12.1 vs torch+cu126） | ✗ 改成 `nvidia/cuda:12.6.3-runtime-ubuntu22.04` 后问题不变 |
| pip 装的 `nvidia-cuda-runtime-cu12` 与 `nvidia-cuda-nvrtc-cu12` 版本错配 | ✗ libcudart.so.12 在容器内/宿主指向同一个 site-packages 路径 |
| `/usr/local/cuda-12.6/compat/libcuda.so.1`（CUDA compat 层）覆盖了 WSL 代理 | ✗ `LD_LIBRARY_PATH=` 清空后仍然失败 |
| seccomp / capabilities 拦截 ioctl | ✗ `--privileged --security-opt seccomp=unconfined` 仍然失败 |
| `NVIDIA_DRIVER_CAPABILITIES` 缺字段 | ✗ 已包含 `compute,utility` |
| `/dev/dxg` 在容器内不可见 | ✗ `ls -la /dev/dxg` 显示 `crw-rw-rw-` |

---

## strace 揭示的根因

在**宿主**直接运行 `python -c "ctypes.CDLL('libcuda.so.1').cuInit(0)"`，strace 显示：

```
openat(AT_FDCWD, "/dev/dxg", O_RDONLY|O_CLOEXEC) = 3
ioctl(3, ...) × 72
openat(AT_FDCWD, "/usr/lib/wsl/drivers/<nv-driver-dir>/libnvdxgdmal.so.1", O_RDONLY) = 10  ← 成功
```

在**容器**内（`docker run --gpus all ...`）跑同样代码：

```
openat(AT_FDCWD, "/dev/dxg", O_RDONLY|O_CLOEXEC) = 3
ioctl(3, ...) × 27  ← 比宿主少很多
openat(AT_FDCWD, "/usr/lib/wsl/drivers/<nv-driver-dir>/libnvdxgdmal.so.1", O_RDONLY) = -1 ENOENT (No such file or directory)  ← 找不到！
```

`libnvdxgdmal.so.1` 是 WSL2 GPU 的 **DXG DMA helper**。WSL 的 `libcuda.so.1`
是一个 162 KB 的**代理**（不是真正的 CUDA driver 实现），它通过 `/dev/dxg`
设备向 Windows 宿主驱动发 ioctl；某些 ioctl 需要 `libnvdxgdmal.so.1` 辅助。

容器内 `libcuda.so.1`（hash `baaf06bccc7bff6804ecabe62e9b3c03`，与宿主同 md5）
虽然存在，但 **`nvidia-container-runtime` 在挂载 WSL 驱动目录时只 cherry-pick
了一部分文件**，漏掉了 `libnvdxgdmal.so.1`：

```
# 容器内 mount 输出（节选）
drivers on /usr/lib/wsl/drivers/<dir>/libcuda.so.1.1            type 9p ...
drivers on /usr/lib/wsl/drivers/<dir>/libcuda_loader.so         type 9p ...
drivers on /usr/lib/wsl/drivers/<dir>/libnvidia-ptxjitcompiler.so.1  type 9p ...
drivers on /usr/lib/wsl/drivers/<dir>/libnvidia-ml.so.1         type 9p ...
drivers on /usr/lib/wsl/drivers/<dir>/libnvidia-ml_loader.so    type 9p ...
drivers on /usr/lib/wsl/drivers/<dir>/nvidia-smi                type 9p ...
drivers on /usr/lib/wsl/drivers/<dir>/nvcubins.bin              type 9p ...
# ↑ libnvdxgdmal.so.1 不在这个列表里
```

`libcuda.so.1` 代理 dlopen 失败 → 后续 `cuInit` 找不到所需符号 → 返回 500。
**注意**：`nvidia-smi` 之所以能跑，是因为它走的代码路径**不需要** `libnvdxgdmal.so.1`；
任何真正发起 compute 工作负载的库（torch / paddle / cupy / 自写 CUDA 程序）都会踩到。

---

## 修复

容器启动时显式 bind-mount 整个 `/usr/lib/wsl/`（只读）：

```bash
docker run --rm --gpus all \
    -v /usr/lib/wsl:/usr/lib/wsl:ro \
    --entrypoint /opt/miniconda3/envs/bishon/bin/python \
    -v /opt/miniconda3/envs/bishon:/opt/miniconda3/envs/bishon \
    bishon-cuda:2.2.0-dev \
    -c 'import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))'
# True NVIDIA GeForce RTX 3080 Laptop GPU
```

`scripts/docker/start.sh` 已经在 WSL 分支自动加上这个 mount（检测条件：
`grep -qi microsoft /proc/version` 且 `/usr/lib/wsl/drivers` 存在）。
原生 Linux 部署不受影响。

---

## 如何监控：`/api/health` 里的 gpu 服务项

`bishon_kernel/monitoring/service_probes.py` 新增了 `probe_gpu()`，每 60 秒跑一次
（`HealthChecker` 周期），结果落在 `/api/health` 响应里：

```json
{
  "services": {
    "gpu": {
      "status": "healthy",
      "detail": "torch cuda=12.6 (NVIDIA GeForce RTX 3080 Laptop GPU) | paddle cuda=ok",
      "latency_ms": 0.08
    }
  }
}
```

健康条件：torch.cuda.is_available() 或 paddle.device.cuda.device_count() 至少
一个返回有可用设备。两者都不可用时 `status=unhealthy`，detail 在 WSL 环境下
直接提示「检查 /usr/lib/wsl:/usr/lib/wsl:ro bind-mount」并指向本文档。

**陷阱：不要用 `paddle.device.is_compiled_with_cuda()` 做这个探针。** 它只查
wheel 是否启用 CUDA 编译，**不做运行时检查**——在 WSL2 缺 libnvdxgdmal 的
场景下，`is_compiled_with_cuda()` 仍然返回 True，而 `paddle.device.cuda.device_count()`
正确返回 0。所以探针必须用 `device_count()`。这条经验适用于 torch 也适用：
`torch.cuda.is_available()` 已经包含运行时检查（它会尝试 cuInit），可以直接用。

前端 Monitor.vue (`/bishon/#/monitor`) 把 gpu 服务项渲染成卡片，title 是
"GPU/CUDA"，状态色和其它服务卡片共用 css。

---

## 验证清单

部署后跑一次自检：

```bash
# 1. 容器里 nvidia-smi
docker exec bishon nvidia-smi

# 2. 容器里 cuInit（直接走 libcuda 代理）
docker exec bishon /opt/miniconda3/envs/bishon/bin/python -c "
import ctypes
cu = ctypes.CDLL('libcuda.so.1')
ret = cu.cuInit(0)
print('cuInit:', ret)
assert ret == 0, f'cuInit failed: {ret}'
"

# 3. 容器里 torch.cuda
docker exec bishon /opt/miniconda3/envs/bishon/bin/python -c "
import torch
assert torch.cuda.is_available()
print('OK:', torch.cuda.get_device_name(0))
"

# 4. 容器里 paddle（注意是 device_count()，不是 is_compiled_with_cuda()）
docker exec bishon /opt/miniconda3/envs/bishon/bin/python -c "
import paddle
assert paddle.device.is_compiled_with_cuda(), 'paddle wheel not CUDA-enabled'
assert paddle.device.cuda.device_count() > 0, 'GPU not usable at runtime'
paddle.device.set_device('gpu')
print('OK: paddle sees', paddle.device.cuda.device_count(), 'GPU(s)')
"

# 5. /api/health 监控（长期观察，每 60s 自动刷新）
curl -fsS http://localhost:8777/api/health | python3 -m json.tool | grep -A4 '"gpu"'
# 期望：
#   "gpu": {
#     "status": "healthy",
#     "detail": "torch cuda=12.6 (...) | paddle cuda=ok",
#   }
# 若 status=unhealthy 且 detail 提示 /usr/lib/wsl → 回到第 1-4 步定位
```

任何一步返回非零或 assertion 失败 → 回查 `docker inspect bishon` 里有没有
`/usr/lib/wsl:/usr/lib/wsl:ro` 这个 mount。

---

## 为什么 nvidia-container-toolkit 没修

到本文档写作时（nvidia-container-toolkit 1.17.x），上游的 WSL2 driver
bind-mount 列表仍未包含 `libnvdxgdmal.so.1`。社区有相关 issue 但修复进度慢。
**临时绕过**就是显式 `-v /usr/lib/wsl:/usr/lib/wsl:ro`，让容器能"看到"完整的
WSL 驱动目录（read-only，安全）。

升级 nvidia-container-toolkit 后建议重新跑上面的验证清单，如果上游修了，
这个 mount 就只是冗余（无副作用，可以保留）。

---

## 历史背景：本仓库是怎么踩到的

1. v2.1.0 用 `nvidia/cuda:12.1.0-runtime-ubuntu22.04` 基础镜像；当时只测了
   `nvidia-smi`，没测 `torch.cuda`。生产部署（Linux + 直连 GPU）一切正常，
   因为 Linux 的 nvidia-container-runtime 直接挂主机 `/usr/lib/x86_64-linux-gnu/libnvidia-*.so`，
   不走 WSL 这套代理路径。

2. 在 WSL2 开发机上跑容器后，发现 `torch.cuda.is_available()=False`。一开始
   怀疑是 CUDA 12.1 base 与 torch+cu126 不匹配（torch wheel 里嵌入的
   `nvidia-cuda-runtime-cu12==12.6.77` 期望 12.6 cudart 符号），把基础镜像
   升到 `12.6.3-runtime-ubuntu22.04` 重新构建 → **问题不变**。这反过来证明
   base 镜像不是根因。

3. strace 对比宿主 vs 容器的 `cuInit` 调用序列，发现容器比宿主少了 45 个
   ioctl，并在第 27 个 ioctl 后试图打开 `libnvdxgdmal.so.1` 失败（ENOENT）。

4. 手动 `-v /usr/lib/wsl:/usr/lib/wsl:ro` 后 torch.cuda 立即恢复。

5. 把这个 mount 加入 `scripts/docker/start.sh` 的 WSL 分支；本文档作为
   长期参考。

---

## 相关文件

- `scripts/docker/start.sh` — `WSL_DRIVER_FLAG` 数组，WSL 分支条件挂载
- `docker/Dockerfile.cuda` — 基础镜像（`nvidia/cuda:12.6.3-runtime-ubuntu22.04`），
  必须匹配 torch/paddle wheel 的 CUDA 版本
- `CHANGELOG.md` / `CHANGELOG.zh-CN.md` — 本修复的 changelog 条目
