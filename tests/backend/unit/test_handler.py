"""Tests for handler validation helpers and download_file endpoint"""
import os
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

from bishon_kernel.bishon_server.handler import (
    CODE_FILE_NOT_FOUND,
    CODE_INVALID_INPUT,
    CODE_INVALID_USER,
    _parse_user_request,
    _UserIdError,
)


def _mock_request(json_body: dict) -> MagicMock:
    """Build a mock Request that returns the given dict from request.json()."""
    request = MagicMock()
    request.json = AsyncMock(return_value=json_body)
    return request


class TestUserIdError:
    def test_carries_body(self):
        body = {"code": CODE_INVALID_INPUT, "msg": "bad"}
        err = _UserIdError(body)
        assert err.body == body

    def test_is_exception(self):
        assert issubclass(_UserIdError, Exception)


class TestParseUserRequest:
    @pytest.mark.asyncio
    async def test_valid_request(self):
        request = _mock_request({"user_id": "alice", "extra": 1})
        user_id, body = await _parse_user_request(request)
        assert user_id == "alice"
        assert body["extra"] == 1

    @pytest.mark.asyncio
    async def test_missing_user_id_raises(self):
        request = _mock_request({"kb_id": "KB123"})
        with pytest.raises(_UserIdError) as exc_info:
            await _parse_user_request(request)
        assert exc_info.value.body["code"] == CODE_INVALID_INPUT

    @pytest.mark.asyncio
    async def test_invalid_user_id_raises(self):
        request = _mock_request({"user_id": "123bad"})
        with pytest.raises(_UserIdError) as exc_info:
            await _parse_user_request(request)
        assert exc_info.value.body["code"] == CODE_INVALID_USER

    @pytest.mark.asyncio
    async def test_none_user_id_raises(self):
        request = _mock_request({"user_id": None})
        with pytest.raises(_UserIdError) as exc_info:
            await _parse_user_request(request)
        assert exc_info.value.body["code"] == CODE_INVALID_INPUT

    @pytest.mark.asyncio
    async def test_empty_string_user_id_raises(self):
        request = _mock_request({"user_id": ""})
        with pytest.raises(_UserIdError) as exc_info:
            await _parse_user_request(request)
        # An empty string passes the None check but is caught by validate_user_id -> code 2005.
        assert exc_info.value.body["code"] == CODE_INVALID_USER


class TestLocalDocChatValidation:
    """Tests for missing/empty field validation in local_doc_chat endpoint."""

    @pytest.fixture
    def mock_app(self):
        app = MagicMock()
        app.state.local_doc_qa = MagicMock()
        return app

    @pytest.mark.asyncio
    async def test_missing_kb_ids_returns_error(self, mock_app):
        """kb_ids=None should return CODE_INVALID_INPUT, not crash."""
        from fastapi import Request

        from bishon_kernel.bishon_server.handler import local_doc_chat

        request = MagicMock(spec=Request)
        request.app = mock_app
        request.json = AsyncMock(return_value={
            "user_id": "alice", "kb_ids": None, "question": "test",
        })

        with pytest.raises(_UserIdError) as exc_info:
            await local_doc_chat(request)
        assert exc_info.value.body["code"] == CODE_INVALID_INPUT

    @pytest.mark.asyncio
    async def test_empty_kb_ids_returns_error(self, mock_app):
        """kb_ids=[] should return CODE_INVALID_INPUT."""
        from fastapi import Request

        from bishon_kernel.bishon_server.handler import local_doc_chat

        request = MagicMock(spec=Request)
        request.app = mock_app
        request.json = AsyncMock(return_value={
            "user_id": "alice", "kb_ids": [], "question": "test",
        })

        with pytest.raises(_UserIdError) as exc_info:
            await local_doc_chat(request)
        assert exc_info.value.body["code"] == CODE_INVALID_INPUT

    @pytest.mark.asyncio
    async def test_missing_question_returns_error(self, mock_app):
        """question=None should return CODE_INVALID_INPUT."""
        import json

        from fastapi import Request

        from bishon_kernel.bishon_server.handler import local_doc_chat

        request = MagicMock(spec=Request)
        request.app = mock_app
        request.json = AsyncMock(return_value={
            "user_id": "alice", "kb_ids": ["KB1"], "question": None,
        })

        result = await local_doc_chat(request)
        body = json.loads(result.body.decode())
        assert body["code"] == CODE_INVALID_INPUT

    @pytest.mark.asyncio
    async def test_empty_question_returns_error(self, mock_app):
        """question='' should return CODE_INVALID_INPUT."""
        import json

        from fastapi import Request

        from bishon_kernel.bishon_server.handler import local_doc_chat

        request = MagicMock(spec=Request)
        request.app = mock_app
        request.json = AsyncMock(return_value={
            "user_id": "alice", "kb_ids": ["KB1"], "question": "",
        })

        result = await local_doc_chat(request)
        body = json.loads(result.body.decode())
        assert body["code"] == CODE_INVALID_INPUT


class TestDeleteKbValidation:
    """Tests for kb_ids validation in delete_knowledge_base endpoint."""

    @pytest.fixture
    def mock_app(self):
        app = MagicMock()
        app.state.local_doc_qa = MagicMock()
        return app

    @pytest.mark.asyncio
    async def test_missing_kb_ids_returns_error(self, mock_app):
        """kb_ids=None should return CODE_INVALID_INPUT, not crash."""
        from fastapi import Request

        from bishon_kernel.bishon_server.handler import delete_knowledge_base

        request = MagicMock(spec=Request)
        request.app = mock_app
        request.json = AsyncMock(return_value={
            "user_id": "alice", "kb_ids": None,
        })

        with pytest.raises(_UserIdError) as exc_info:
            await delete_knowledge_base(request)
        assert exc_info.value.body["code"] == CODE_INVALID_INPUT

    @pytest.mark.asyncio
    async def test_empty_kb_ids_returns_error(self, mock_app):
        """kb_ids=[] should return CODE_INVALID_INPUT."""
        from fastapi import Request

        from bishon_kernel.bishon_server.handler import delete_knowledge_base

        request = MagicMock(spec=Request)
        request.app = mock_app
        request.json = AsyncMock(return_value={
            "user_id": "alice", "kb_ids": [],
        })

        with pytest.raises(_UserIdError) as exc_info:
            await delete_knowledge_base(request)
        assert exc_info.value.body["code"] == CODE_INVALID_INPUT


# ---- download_file endpoint tests (TDD: written before implementation) ----

class TestDownloadFile:
    """Tests for GET /api/local_doc_qa/download_file/{file_id}"""

    @pytest.fixture
    def download_client(self, tmp_path, monkeypatch):
        """Set up a TestClient with real SQLite + temp upload directory."""
        import bishon_kernel.configs.model_config as config_mod
        import bishon_kernel.connector.database.sqlite.sqlite_client as sqlite_mod

        # Redirect SQLite to temp directory
        db_dir = str(tmp_path / "db")
        os.makedirs(db_dir, exist_ok=True)
        monkeypatch.setattr(sqlite_mod, "DB_DIR", db_dir)
        monkeypatch.setattr(sqlite_mod, "DB_PATH", os.path.join(db_dir, "test.db"))

        # Redirect upload path to temp directory
        upload_dir = str(tmp_path / "content")
        os.makedirs(upload_dir, exist_ok=True)
        monkeypatch.setattr(config_mod, "UPLOAD_ROOT_PATH", upload_dir)

        # Build a minimal FastAPI app with just the download router
        from fastapi import FastAPI

        from bishon_kernel.bishon_server.handler import router
        from bishon_kernel.connector.database.sqlite.sqlite_client import KnowledgeBaseManager

        app = FastAPI()
        app.include_router(router)

        kb_mgr = KnowledgeBaseManager()
        mock_local_doc_qa = MagicMock()
        mock_local_doc_qa.kb_manager = kb_mgr
        app.state.local_doc_qa = mock_local_doc_qa

        return TestClient(app), kb_mgr, upload_dir

    def _seed_file(self, kb_mgr, upload_dir, user_id="testuser", kb_name="testkb",
                   file_name="test.txt", file_content=b"hello world", deleted=0):
        """Helper: create user + KB + file record + on-disk file, return file_id."""
        kb_mgr.add_user_(user_id)
        kb_id = "KB" + "a" * 28
        kb_mgr._execute(
            "INSERT INTO KnowledgeBase (kb_id, user_id, kb_name) VALUES (?, ?, ?)",
            (kb_id, user_id, kb_name), commit=True,
        )
        file_id = "f" * 32
        kb_mgr._execute(
            "INSERT INTO File (file_id, kb_id, file_name, status, timestamp, deleted) "
            "VALUES (?, ?, ?, 'green', '202605211000', ?)",
            (file_id, kb_id, file_name, deleted), commit=True,
        )
        # Create on-disk file
        file_dir = os.path.join(upload_dir, user_id, file_id)
        os.makedirs(file_dir, exist_ok=True)
        with open(os.path.join(file_dir, file_name), "wb") as f:
            f.write(file_content)
        return file_id

    def test_download_file_success(self, download_client):
        """Normal file download returns file content with Content-Disposition attachment."""
        client, kb_mgr, upload_dir = download_client
        file_id = self._seed_file(kb_mgr, upload_dir, file_content=b"traceability test")

        resp = client.get(f"/api/local_doc_qa/download_file/{file_id}")
        assert resp.status_code == 200
        assert resp.content == b"traceability test"
        assert "content-disposition" in resp.headers
        assert resp.headers["content-disposition"].startswith("attachment")
        assert "test.txt" in resp.headers["content-disposition"]

    def test_download_file_not_found_in_db(self, download_client):
        """Non-existent file_id returns 404."""
        client, _, _ = download_client
        resp = client.get("/api/local_doc_qa/download_file/nonexistent0000000000000000")
        assert resp.status_code == 404
        assert resp.json()["code"] == CODE_FILE_NOT_FOUND

    def test_download_file_deleted(self, download_client):
        """Soft-deleted file returns 404."""
        client, kb_mgr, upload_dir = download_client
        file_id = self._seed_file(kb_mgr, upload_dir, deleted=1)

        resp = client.get(f"/api/local_doc_qa/download_file/{file_id}")
        assert resp.status_code == 404
        assert resp.json()["code"] == CODE_FILE_NOT_FOUND

    def test_download_file_missing_on_disk(self, download_client):
        """DB record exists but file missing on disk returns 404."""
        client, kb_mgr, upload_dir = download_client
        file_id = self._seed_file(kb_mgr, upload_dir)
        # Remove the on-disk file
        file_dir = os.path.join(upload_dir, "testuser", file_id)
        for f in os.listdir(file_dir):
            os.remove(os.path.join(file_dir, f))

        resp = client.get(f"/api/local_doc_qa/download_file/{file_id}")
        assert resp.status_code == 404
        assert resp.json()["code"] == CODE_FILE_NOT_FOUND

    def test_download_url_type_redirects(self, download_client):
        """URL-type file_name returns 302 redirect."""
        client, kb_mgr, upload_dir = download_client
        url = "https://example.com/page.html"
        # URL-type files don't need a disk file, only a database record.
        file_id = "b" * 32  # valid hex file_id
        kb_mgr.add_user_("testuser")
        kb_mgr._execute(
            "INSERT INTO KnowledgeBase (kb_id, user_id, kb_name) VALUES (?, ?, ?)",
            ("KB" + "b" * 28, "testuser", "testkb"), commit=True,
        )
        kb_mgr._execute(
            "INSERT INTO File (file_id, kb_id, file_name, status, timestamp, deleted) "
            "VALUES (?, ?, ?, 'green', '202605211000', 0)",
            (file_id, "KB" + "b" * 28, url), commit=True,
        )

        resp = client.get(f"/api/local_doc_qa/download_file/{file_id}",
                          follow_redirects=False)
        assert resp.status_code == 302
        assert resp.headers["location"] == url

    def test_download_invalid_file_id_format(self, download_client):
        """Invalid file_id format (not 32-char hex) returns 404."""
        client, _, _ = download_client
        resp = client.get("/api/local_doc_qa/download_file/short")
        assert resp.status_code == 404
        assert resp.json()["code"] == CODE_FILE_NOT_FOUND

        resp = client.get("/api/local_doc_qa/download_file/GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG")
        assert resp.status_code == 404

    def test_download_path_traversal_rejected(self, download_client):
        """file_name with path traversal characters returns 404."""
        client, kb_mgr, upload_dir = download_client
        file_id = "p" * 32
        kb_mgr.add_user_("testuser")
        kb_mgr._execute(
            "INSERT INTO KnowledgeBase (kb_id, user_id, kb_name) VALUES (?, ?, ?)",
            ("KB" + "c" * 28, "testuser", "testkb"), commit=True,
        )
        kb_mgr._execute(
            "INSERT INTO File (file_id, kb_id, file_name, status, timestamp, deleted) "
            "VALUES (?, ?, ?, 'green', '202605211000', 0)",
            (file_id, "KB" + "c" * 28, "../../../etc/passwd"), commit=True,
        )

        resp = client.get(f"/api/local_doc_qa/download_file/{file_id}")
        assert resp.status_code == 404
        assert resp.json()["code"] == CODE_FILE_NOT_FOUND

    def test_download_file_name_none(self, download_client):
        """file_name=None in DB returns 404 instead of crashing."""
        client, kb_mgr, upload_dir = download_client
        file_id = "n" * 32
        kb_mgr.add_user_("testuser")
        kb_mgr._execute(
            "INSERT INTO KnowledgeBase (kb_id, user_id, kb_name) VALUES (?, ?, ?)",
            ("KB" + "d" * 28, "testuser", "testkb"), commit=True,
        )
        kb_mgr._execute(
            "INSERT INTO File (file_id, kb_id, file_name, status, timestamp, deleted) "
            "VALUES (?, ?, ?, 'green', '202605211000', 0)",
            (file_id, "KB" + "d" * 28, None), commit=True,
        )

        resp = client.get(f"/api/local_doc_qa/download_file/{file_id}")
        assert resp.status_code == 404
        assert resp.json()["code"] == CODE_FILE_NOT_FOUND
