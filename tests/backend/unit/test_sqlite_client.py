"""Tests for KnowledgeBaseManager SQLite CRUD operations."""
import os

import pytest


class TestCreateTables:
    def test_creates_tables(self, tmp_db):
        assert tmp_db is not None

    def test_idempotent(self, tmp_db):
        tmp_db.create_tables_()


class TestUserOperations:
    def test_add_user(self, tmp_db):
        tmp_db.add_user_("user1", "Test User")
        assert tmp_db.check_user_exist_("user1") is True

    def test_add_user_duplicate_ignore(self, tmp_db):
        tmp_db.add_user_("user1")
        tmp_db.add_user_("user1")
        assert tmp_db.check_user_exist_("user1") is True

    def test_check_user_not_exist(self, tmp_db):
        assert tmp_db.check_user_exist_("nonexistent") is False

    def test_get_users(self, tmp_db):
        tmp_db.add_user_("u1")
        tmp_db.add_user_("u2")
        users = tmp_db.get_users()
        assert len(users) >= 2


class TestKnowledgeBaseOperations:
    def test_new_kb(self, tmp_db):
        kb_id, msg = tmp_db.new_milvus_base("KB001", "user1", "Test KB")
        assert kb_id == "KB001"
        assert msg == "success"

    def test_new_kb_auto_creates_user(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "new_user", "Test KB")
        assert tmp_db.check_user_exist_("new_user") is True

    def test_check_kb_exist_found(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "Test KB")
        not_exist = tmp_db.check_kb_exist("user1", ["KB001"])
        assert not_exist == []

    def test_check_kb_exist_not_found(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "Test KB")
        not_exist = tmp_db.check_kb_exist("user1", ["KB999"])
        assert not_exist == ["KB999"]

    def test_check_kb_exist_empty_list(self, tmp_db):
        assert tmp_db.check_kb_exist("user1", []) == []

    def test_check_kb_exist_soft_deleted(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "Test KB")
        tmp_db.delete_knowledge_base("user1", ["KB001"])
        not_exist = tmp_db.check_kb_exist("user1", ["KB001"])
        assert not_exist == ["KB001"]

    def test_get_knowledge_bases(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "KB One")
        tmp_db.new_milvus_base("KB002", "user1", "KB Two")
        kbs = tmp_db.get_knowledge_bases("user1")
        assert len(kbs) == 2
        names = [kb[1] for kb in kbs]
        assert "KB One" in names and "KB Two" in names

    def test_get_knowledge_bases_empty(self, tmp_db):
        tmp_db.add_user_("user1")
        assert tmp_db.get_knowledge_bases("user1") == []

    def test_get_knowledge_bases_excludes_deleted(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "Visible")
        tmp_db.new_milvus_base("KB002", "user1", "Deleted")
        tmp_db.delete_knowledge_base("user1", ["KB002"])
        kbs = tmp_db.get_knowledge_bases("user1")
        assert len(kbs) == 1
        assert kbs[0][1] == "Visible"

    def test_delete_knowledge_base(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "Test KB")
        tmp_db.delete_knowledge_base("user1", ["KB001"])
        assert tmp_db.get_knowledge_bases("user1") == []

    def test_delete_kb_cascades_files(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "Test KB")
        tmp_db.add_file("user1", "KB001", "test.txt", "20240101")
        tmp_db.delete_knowledge_base("user1", ["KB001"])
        files = tmp_db.get_files("user1", "KB001")
        assert len(files) == 0

    def test_rename_knowledge_base(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "Old Name")
        tmp_db.rename_knowledge_base("user1", "KB001", "New Name")
        kbs = tmp_db.get_knowledge_bases("user1")
        assert kbs[0][1] == "New Name"

    def test_get_knowledge_base_name(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "Test KB")
        result = tmp_db.get_knowledge_base_name(["KB001"])
        assert len(result) == 1
        assert result[0][2] == "Test KB"


class TestFileOperations:
    def _setup_kb(self, db, user_id="user1", kb_id="KB001"):
        db.new_milvus_base(kb_id, user_id, "Test KB")
        return user_id, kb_id

    def test_add_file(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        file_id, msg = tmp_db.add_file(user_id, kb_id, "test.txt", "20240101")
        assert file_id is not None
        assert msg == "success"

    def test_add_file_invalid_user(self, tmp_db):
        file_id, msg = tmp_db.add_file("nonexistent", "KB001", "test.txt", "20240101")
        assert file_id is None
        assert "invalid user_id" in msg

    def test_add_file_invalid_kb(self, tmp_db):
        tmp_db.add_user_("user1")
        file_id, msg = tmp_db.add_file("user1", "KB999", "test.txt", "20240101")
        assert file_id is None

    def test_get_files(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.add_file(user_id, kb_id, "b.txt", "20240101")
        files = tmp_db.get_files(user_id, kb_id)
        assert len(files) == 2

    def test_get_files_excludes_deleted(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.add_file(user_id, kb_id, "b.txt", "20240101")
        tmp_db.delete_files(kb_id, [f1])
        files = tmp_db.get_files(user_id, kb_id)
        assert len(files) == 1

    def test_delete_files(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.delete_files(kb_id, [f1])
        files = tmp_db.get_files(user_id, kb_id)
        assert len(files) == 0

    def test_delete_files_empty_list(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        tmp_db.delete_files(kb_id, [])

    def test_update_file_status(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.update_file_status(f1, "green")
        files = tmp_db.get_files(user_id, kb_id)
        assert files[0][2] == "green"

    def test_status_transitions(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.update_file_status(f1, "red")
        assert tmp_db.get_files(user_id, kb_id)[0][2] == "red"
        tmp_db.update_file_status(f1, "green")
        assert tmp_db.get_files(user_id, kb_id)[0][2] == "green"

    def test_get_file_by_status(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.update_file_status(f1, "green")
        green = tmp_db.get_file_by_status([kb_id], "green")
        assert len(green) == 1
        gray = tmp_db.get_file_by_status([kb_id], "gray")
        assert len(gray) == 0

    def test_check_file_exist(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        result = tmp_db.check_file_exist(user_id, kb_id, [f1])
        assert len(result) > 0

    def test_check_file_exist_cross_user_isolation(self, tmp_db):
        tmp_db.new_milvus_base("KB001", "user1", "KB1")
        tmp_db.new_milvus_base("KB002", "user2", "KB2")
        f1, _ = tmp_db.add_file("user1", "KB001", "a.txt", "20240101")
        result = tmp_db.check_file_exist("user2", "KB002", [f1])
        assert len(result) == 0

    def test_check_file_exist_by_name(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        tmp_db.add_file(user_id, kb_id, "test.txt", "20240101")
        result = tmp_db.check_file_exist_by_name(user_id, kb_id, ["test.txt"])
        assert len(result) == 1

    def test_check_file_exist_by_name_not_found(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        result = tmp_db.check_file_exist_by_name(user_id, kb_id, ["nonexistent.txt"])
        assert len(result) == 0

    def test_update_file_size(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.update_file_size(f1, 1024)
        files = tmp_db.get_files(user_id, kb_id)
        assert files[0][3] == 1024

    def test_update_content_length(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.update_content_length(f1, 500)
        files = tmp_db.get_files(user_id, kb_id)
        assert files[0][4] == 500

    def test_from_status_to_status(self, tmp_db):
        user_id, kb_id = self._setup_kb(tmp_db)
        f1, _ = tmp_db.add_file(user_id, kb_id, "a.txt", "20240101")
        tmp_db.from_status_to_status([f1], "gray", "green")
        files = tmp_db.get_files(user_id, kb_id)
        assert files[0][2] == "green"


class TestFTS5Operations:
    def test_insert_and_search(self, tmp_db):
        import sqlite3
        try:
            conn = sqlite3.connect(":memory:")
            conn.execute("CREATE VIRTUAL TABLE t USING fts5(c)")
            conn.close()
        except Exception:
            pytest.skip("FTS5 not available")

        result = tmp_db.insert_fts_chunks("f1", "test.txt", ["hello world", "foo bar"])
        assert result is True
        found = tmp_db.search_fts("hello")
        assert len(found) > 0

    def test_delete_fts_chunks(self, tmp_db):
        import sqlite3
        try:
            conn = sqlite3.connect(":memory:")
            conn.execute("CREATE VIRTUAL TABLE t USING fts5(c)")
            conn.close()
        except Exception:
            pytest.skip("FTS5 not available")

        tmp_db.insert_fts_chunks("f1", "test.txt", ["hello world"])
        tmp_db.delete_fts_chunks(["f1"])
        found = tmp_db.search_fts("hello")
        assert len(found) == 0


class TestSchemaValidation:
    """Tests for schema validation at startup."""

    def test_normal_schema_passes(self, tmp_db):
        """A normal schema passes validation without raising."""
        # tmp_db already validated schema in __init__
        assert tmp_db is not None

    def test_missing_column_raises(self, tmp_path, monkeypatch):
        """A missing required column should raise at startup."""
        import sqlite3

        import bishon_kernel.connector.database.sqlite.sqlite_client as sqlite_mod

        db_dir = str(tmp_path / "db")
        os.makedirs(db_dir, exist_ok=True)
        db_path = os.path.join(db_dir, "test.db")
        monkeypatch.setattr(sqlite_mod, "DB_DIR", db_dir)
        monkeypatch.setattr(sqlite_mod, "DB_PATH", db_path)

        # First create a table with missing columns.
        conn = sqlite3.connect(db_path)
        conn.execute("CREATE TABLE IF NOT EXISTS User (user_id TEXT PRIMARY KEY)")
        conn.execute("PRAGMA journal_mode=WAL")
        conn.commit()
        conn.close()

        with pytest.raises(RuntimeError, match="Schema校验失败"):
            sqlite_mod.KnowledgeBaseManager()
