# Bishon V2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/)
[![Vue 3](https://img.shields.io/badge/Vue-3.3-brightgreen.svg)](https://vuejs.org/)
[![CI](https://github.com/dliting/Bishon/actions/workflows/ci.yml/badge.svg)](https://github.com/dliting/Bishon/actions/workflows/ci.yml)

**本地优先的知识库问答系统**——无 Docker、无云端、无微服务集群，只有 FastAPI + FAISS + SQLite 在裸机上运行。

[English](README.md) | 简体中文

---

## 特性

- **单进程部署**——用一条 `uvicorn` 命令替代原版 6+ 容器的 Docker Compose 方案。
- **多格式文档解析**——PDF、Word（docx）、PPT、TXT、图片（jpg/png/jpeg）、CSV、Excel、EML、Markdown 以及任意网页链接。
- **进程内 PaddleOCR 3.x**——无需独立 OCR 微服务。
- **进程内 Rerank**——通过 `transformers` 加载 Qwen3-Reranker，无需 Triton。
- **外接 LLM / Embedding**——自带 Ollama、vLLM 或任何 OpenAI 兼容端点。
- **可选 GPU 加速**——FAISS、Rerank、OCR 都有独立的 GPU 开关。
- **文档溯源**——点击来源文档可在浏览器中打开原始文件。
- **SSE 流式问答**——回答按 token 流式输出。

## 截图

<!-- TODO：发布前替换为真实截图。 -->

```
[带流式回答 + 来源文档面板的问答界面]
[知识库管理界面]
[多格式上传弹窗]
```

## 架构

```
知识库服务 (FastAPI, port 8777)
├── FAISS（向量检索）
├── SQLite + FTS5（元数据 + 全文）
├── PaddleOCR（文档识别）
└── Rerank（进程内 transformers）
        │
        │ HTTP（通过配置连接）
        ▼
外部模型服务（独立启动，可被其他程序共用）
├── Ollama / OpenAI API (LLM)
└── Ollama / OpenAI API (Embedding)
```

### 项目结构

```
Bishon/V2/
├── bishon_kernel/          核心代码
│   ├── configs/            配置（.env 唯一加载入口）
│   ├── connector/          数据连接层
│   │   ├── database/       FAISS + SQLite
│   │   ├── embedding/      OpenAI 兼容 Embedding
│   │   ├── rerank/         进程内 Rerank
│   │   └── llm/            OpenAI 兼容 LLM
│   ├── core/               核心问答 + 文件处理
│   ├── bishon_server/      FastAPI 服务层 + 已构建的前端 dist
│   └── utils/              工具函数
├── BISHON_DB/              数据目录（自动创建）
│   ├── metadata.db         SQLite 元数据
│   ├── faiss/              FAISS 向量索引
│   └── content/            上传文件
├── logs/                   日志
├── .env                    配置文件（gitignored；从 .env.example 复制）
├── requirements.txt        Python 依赖
├── start.sh                Linux 启动脚本
└── start.bat               Windows 启动脚本
```

## 环境要求

- Python 3.11+
- 提供 OpenAI 兼容 API 的 LLM 服务（Ollama / vLLM / OpenAI）
- 提供 OpenAI 兼容 API 的 Embedding 服务（Ollama / OpenAI）
- （可选）NVIDIA GPU + CUDA 用于加速

## 快速开始

```bash
# 1. 创建 conda 环境
conda create -n bishon python=3.11 -y
conda activate bishon

# 2. 安装依赖
pip install -r requirements.txt

# 3. 配置
cp .env.example .env
# 编辑 .env：设置 OPENAI_API_BASE / OPENAI_API_KEY / EMBEDDING_API_BASE 等

# 4. 构建前端（dist/ 不存在时才需要）
cd front_end && npm ci && npm run build && cd ..

# 5. 启动
./start.sh        # Linux / WSL
start.bat         # Windows
```

服务启动后访问 <http://localhost:8777>。UI 入口：<http://localhost:8777/bishon/>；API 概览：<http://localhost:8777/api/docs>。

## 配置说明（`.env`）

完整模板见 `.env.example`。常用项：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `OPENAI_API_BASE` | LLM 服务地址 | `http://localhost:11434/v1` |
| `OPENAI_API_MODEL_NAME` | LLM 模型名 | `qwen3:14b` |
| `OPENAI_API_KEY` | LLM API key | `EMPTY`（本地 Ollama 用） |
| `OPENAI_API_CONTEXT_LENGTH` | LLM 上下文长度 | `8192` |
| `LLM_PROVIDER` | 适配器选择：`openai` / `ollama` / `minimax` | `openai` |
| `EMBEDDING_API_BASE` | Embedding 服务地址 | `http://localhost:11434/v1/embeddings` |
| `EMBEDDING_MODEL_NAME` | Embedding 模型 | `qwen3-embedding:0.6b` |
| `RERANK_MODEL_PATH` | 本地 Rerank 模型路径 | `models/Qwen3-Reranker-0.6B` |
| `RERANK_ENABLED` | 是否启用进程内 Rerank | `false` |
| `FAISS_EMBEDDING_DIM` | 必须与 Embedding 模型维度一致 | `1024` |
| `DOC_SCORE_THRESHOLD` | 返回参考文档所需的最低平均相关性 | `0.65` |
| `VECTOR_DB_USE_GPU` / `RERANK_USE_GPU` / `OCR_USE_GPU` | 各组件 GPU 开关 | `true` |

## API 接口

所有接口文档见 `GET /api/docs`。字段级文档见 `docs/API.md`。

| 方法 | 路径 | 说明 |
|------|------|------|
| GET  | `/api/health` | 健康探测 |
| POST | `/api/local_doc_qa/new_knowledge_base` | 新建知识库 |
| POST | `/api/local_doc_qa/upload_files` | 上传文件 |
| POST | `/api/local_doc_qa/upload_weblink` | 上传网页链接 |
| POST | `/api/local_doc_qa/local_doc_chat` | 问答（支持 SSE 流式） |
| POST | `/api/local_doc_qa/list_knowledge_base` | 知识库列表 |
| POST | `/api/local_doc_qa/list_files` | 文件列表 |
| POST | `/api/local_doc_qa/get_total_status` | 状态查询 |
| POST | `/api/local_doc_qa/clean_files_by_status` | 按状态清理文件 |
| POST | `/api/local_doc_qa/delete_files` | 删除文件 |
| POST | `/api/local_doc_qa/delete_knowledge_base` | 删除知识库 |
| POST | `/api/local_doc_qa/rename_knowledge_base` | 重命名知识库 |
| GET  | `/api/local_doc_qa/download_file/{file_id}` | 下载原始文件（文档溯源） |
| GET  | `/api/docs` | API 概览（纯文本） |

## 与传统 RAG 方案对比

Bishon V2 把重量级微服务栈换成单进程部署，一台工作站就能跑：

| 组件 | 传统方案（Docker Compose） | Bishon V2 |
|------|----------------------------|-----------|
| 向量库 | Milvus + etcd + MinIO | FAISS（文件持久化） |
| 元数据 | MySQL | SQLite（WAL 模式） |
| 全文检索 | Elasticsearch | SQLite FTS5（默认关闭） |
| Embedding | Triton（本地 GPU） | 外部 HTTP（Ollama / OpenAI） |
| Rerank | Triton（本地 GPU） | 进程内 Qwen3-Reranker |
| LLM | FastChat / vLLM / FasterTransformer | 外部 HTTP（Ollama / OpenAI） |
| OCR | PaddleOCR 微服务 | 进程内 PaddleOCR 3.x |
| Web 框架 | Sanic | FastAPI |
| 部署 | Docker Compose（6+ 容器） | 单命令启动 |

## Roadmap

- **v2.0**（当前版本）：裸金属单进程部署，MIT 协议，双语文档，GitHub Actions CI。
- **v2.1**：可选 Docker / docker-compose 部署，MkDocs 文档站（GitHub Pages）。
- **v2.2**：多模态文档（音视频转写），可插拔存储后端。

## 致谢

架构启发自 [NetEase QAnything](https://github.com/netease-youdao/QAnything)。本仓库所有代码均为从头重写。详见 `NOTICE`。

## 商标说明

"Bishon" 仅作为项目名使用。如有冲突商标，请通过 Issue 联系。

## 许可证

[MIT](LICENSE) — Copyright (c) 2026 The Bishon V2 Authors.
