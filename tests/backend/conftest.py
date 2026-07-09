"""Bishon V2 backend test global fixtures."""
import os

import pytest


@pytest.fixture
def tmp_db(tmp_path, monkeypatch):
    """Each test gets an isolated temporary SQLite database."""
    import bishon_kernel.connector.database.sqlite.sqlite_client as sqlite_mod
    monkeypatch.setattr(sqlite_mod, "DB_DIR", str(tmp_path))
    monkeypatch.setattr(sqlite_mod, "DB_PATH", str(tmp_path / "test.db"))
    from bishon_kernel.connector.database.sqlite.sqlite_client import KnowledgeBaseManager
    return KnowledgeBaseManager()


@pytest.fixture
def tmp_faiss_dir(tmp_path, monkeypatch):
    """Each test gets an isolated temporary FAISS directory."""
    import bishon_kernel.connector.database.faiss.faiss_client as faiss_mod
    faiss_dir = str(tmp_path / "faiss")
    os.makedirs(faiss_dir, exist_ok=True)
    monkeypatch.setattr(faiss_mod, "FAISS_DIR", faiss_dir)
    return faiss_dir


@pytest.fixture
def tmp_faiss(tmp_path, monkeypatch):
    """Each test gets an isolated FaissClient (CPU-only) + temporary SQLite."""
    import bishon_kernel.connector.database.faiss.faiss_client as faiss_mod
    import bishon_kernel.connector.database.sqlite.sqlite_client as sqlite_mod

    db_dir = str(tmp_path / "db")
    os.makedirs(db_dir, exist_ok=True)
    monkeypatch.setattr(sqlite_mod, "DB_DIR", db_dir)
    monkeypatch.setattr(sqlite_mod, "DB_PATH", os.path.join(db_dir, "test.db"))

    faiss_dir = str(tmp_path / "faiss")
    os.makedirs(faiss_dir, exist_ok=True)
    monkeypatch.setattr(faiss_mod, "FAISS_DIR", faiss_dir)

    monkeypatch.setenv("VECTOR_DB_USE_GPU", "false")

    from bishon_kernel.connector.database.faiss.faiss_client import FaissClient
    from bishon_kernel.connector.database.sqlite.sqlite_client import KnowledgeBaseManager

    kb_mgr = KnowledgeBaseManager()
    return FaissClient("test_user", ["KB_test"], threshold=1.1, kb_manager=kb_mgr)
