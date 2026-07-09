"""SQLite metadata store + FTS5 full-text search (replaces MySQL + Elasticsearch)."""
import os
import sqlite3
import uuid

from bishon_kernel.configs.model_config import root_path
from bishon_kernel.utils.custom_log import debug_logger

DB_DIR = os.path.join(root_path, 'BISHON_DB')
DB_PATH = os.path.join(DB_DIR, 'metadata.db')

SQLITE_BUSY_TIMEOUT_MS = 2000


class KnowledgeBaseManager:
    """SQLite-based knowledge base metadata manager, replacing MySQL."""

    def __init__(self):
        os.makedirs(DB_DIR, exist_ok=True)
        self.create_tables_()
        debug_logger.info("[SUCCESS] SQLite 数据库连接成功: %s", DB_PATH)

    def _execute(self, query, params=(), commit=False, fetch=False):
        """Execute a query with a new connection each time for thread safety."""
        conn = sqlite3.connect(DB_PATH, timeout=10)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute(f"PRAGMA busy_timeout={SQLITE_BUSY_TIMEOUT_MS}")
        try:
            cursor = conn.cursor()
            cursor.execute(query, params)
            if commit:
                conn.commit()
            if fetch:
                result = cursor.fetchall()
            else:
                result = None
            cursor.close()
            return result
        finally:
            conn.close()

    def create_tables_(self):
        query = """
            CREATE TABLE IF NOT EXISTS User (
                user_id TEXT PRIMARY KEY,
                user_name TEXT
            );
        """
        self._execute(query, commit=True)

        query = """
            CREATE TABLE IF NOT EXISTS KnowledgeBase (
                kb_id TEXT PRIMARY KEY,
                user_id TEXT,
                kb_name TEXT,
                deleted INTEGER DEFAULT 0,
                FOREIGN KEY (user_id) REFERENCES User(user_id) ON DELETE CASCADE
            );
        """
        self._execute(query, commit=True)

        query = """
            CREATE TABLE IF NOT EXISTS File (
                file_id TEXT PRIMARY KEY,
                kb_id TEXT,
                file_name TEXT,
                status TEXT,
                timestamp TEXT,
                deleted INTEGER DEFAULT 0,
                file_size INTEGER DEFAULT -1,
                content_length INTEGER DEFAULT -1,
                chunk_size INTEGER DEFAULT -1,
                FOREIGN KEY (kb_id) REFERENCES KnowledgeBase(kb_id) ON DELETE CASCADE
            );
        """
        self._execute(query, commit=True)

        # FTS5 virtual table for full-text search (disabled by default)
        query = """
            CREATE VIRTUAL TABLE IF NOT EXISTS FileChunkFTS USING fts5(
                content,
                file_id,
                file_name,
                chunk_id
            );
        """
        try:
            self._execute(query, commit=True)
        except Exception as e:
            debug_logger.warning("FTS5 创建失败（可能是旧版本 SQLite）: %s", e)

        debug_logger.info("[SUCCESS] SQLite 表结构检查通过")
        self._validate_schema()

    REQUIRED_COLUMNS = {
        'User':           {'user_id', 'user_name'},
        'KnowledgeBase':  {'kb_id', 'user_id', 'kb_name', 'deleted'},
        'File':           {'file_id', 'kb_id', 'file_name', 'status',
                           'timestamp', 'deleted', 'file_size',
                           'content_length', 'chunk_size'},
    }

    def _validate_schema(self):
        """Validate required columns at startup; raise and exit if any are missing."""
        for table, required in self.REQUIRED_COLUMNS.items():
            rows   = self._execute(f"PRAGMA table_info({table})", fetch=True)
            existing = {row[1] for row in rows}
            missing = required - existing
            if missing:
                raise RuntimeError(
                    f"Schema校验失败: 表 '{table}' 缺少列 {missing}，请检查数据库"
                )

    # ---- User ----
    def check_user_exist_(self, user_id):
        result = self._execute(
            "SELECT user_id FROM User WHERE user_id = ?", (user_id,), fetch=True
        )
        return result is not None and len(result) > 0

    def add_user_(self, user_id, user_name=None):
        self._execute(
            "INSERT OR IGNORE INTO User (user_id, user_name) VALUES (?, ?)",
            (user_id, user_name), commit=True
        )
        return user_id

    def get_users(self):
        result = self._execute("SELECT user_id FROM User", fetch=True)
        return result

    # ---- KnowledgeBase ----
    def new_milvus_base(self, kb_id, user_id, kb_name, user_name=None):
        """Interface-compat name; internally backed by SQLite."""
        if not self.check_user_exist_(user_id):
            self.add_user_(user_id, user_name)
        self._execute(
            "INSERT INTO KnowledgeBase (kb_id, user_id, kb_name) VALUES (?, ?, ?)",
            (kb_id, user_id, kb_name), commit=True
        )
        return kb_id, "success"

    def check_kb_exist(self, user_id, kb_ids):
        if not kb_ids:
            return []
        placeholders = ','.join(['?'] * len(kb_ids))
        query = f"SELECT kb_id FROM KnowledgeBase WHERE kb_id IN ({placeholders}) AND deleted = 0 AND user_id = ?"
        result = self._execute(query, tuple(kb_ids) + (user_id,), fetch=True)
        valid_kb_ids = [r[0] for r in result]
        return list(set(kb_ids) - set(valid_kb_ids))

    def get_knowledge_bases(self, user_id):
        result = self._execute(
            "SELECT kb_id, kb_name FROM KnowledgeBase WHERE user_id = ? AND deleted = 0",
            (user_id,), fetch=True
        )
        return result

    def get_knowledge_base_name(self, kb_ids):
        if not kb_ids:
            return []
        placeholders = ','.join(['?'] * len(kb_ids))
        query = f"SELECT user_id, kb_id, kb_name FROM KnowledgeBase WHERE kb_id IN ({placeholders}) AND deleted = 0"
        return self._execute(query, tuple(kb_ids), fetch=True)

    def delete_knowledge_base(self, user_id, kb_ids):
        if not kb_ids:
            return
        placeholders = ','.join(['?'] * len(kb_ids))
        query = f"UPDATE KnowledgeBase SET deleted = 1 WHERE user_id = ? AND kb_id IN ({placeholders})"
        self._execute(query, (user_id,) + tuple(kb_ids), commit=True)
        query = f"UPDATE File SET deleted = 1 WHERE kb_id IN ({placeholders}) AND kb_id IN (SELECT kb_id FROM KnowledgeBase WHERE user_id = ?)"
        self._execute(query, tuple(kb_ids) + (user_id,), commit=True)
        debug_logger.info("delete_knowledge_base: %s", kb_ids)

    def rename_knowledge_base(self, user_id, kb_id, kb_name):
        self._execute(
            "UPDATE KnowledgeBase SET kb_name = ? WHERE kb_id = ? AND user_id = ?",
            (kb_name, kb_id, user_id), commit=True
        )
        debug_logger.info("rename_knowledge_base: %s", kb_id)

    # ---- File ----
    def add_file(self, user_id, kb_id, file_name, timestamp, status="gray"):
        if not self.check_user_exist_(user_id):
            return None, "invalid user_id, please check..."
        not_exist = self.check_kb_exist(user_id, [kb_id])
        if not_exist:
            return None, f"invalid kb_id, please check {not_exist}"
        file_id = uuid.uuid4().hex
        self._execute(
            "INSERT INTO File (file_id, kb_id, file_name, status, timestamp) VALUES (?, ?, ?, ?, ?)",
            (file_id, kb_id, file_name, status, timestamp), commit=True
        )
        debug_logger.info("add_file: %s", file_id)
        return file_id, "success"

    def update_file_size(self, file_id, file_size):
        self._execute("UPDATE File SET file_size = ? WHERE file_id = ?", (file_size, file_id), commit=True)

    def update_content_length(self, file_id, content_length):
        self._execute("UPDATE File SET content_length = ? WHERE file_id = ?", (content_length, file_id), commit=True)

    def update_chunk_size(self, file_id, chunk_size):
        self._execute("UPDATE File SET chunk_size = ? WHERE file_id = ?", (chunk_size, file_id), commit=True)

    def update_file_status(self, file_id, status):
        self._execute("UPDATE File SET status = ? WHERE file_id = ?", (status, file_id), commit=True)

    def get_file_by_status(self, kb_ids, status):
        if not kb_ids:
            return []
        placeholders = ','.join(['?'] * len(kb_ids))
        query = f"SELECT file_id, file_name FROM File WHERE kb_id IN ({placeholders}) AND deleted = 0 AND status = ?"
        return self._execute(query, tuple(kb_ids) + (status,), fetch=True)

    def check_file_exist(self, user_id, kb_id, file_ids):
        if not file_ids:
            return []
        placeholders = ','.join(['?'] * len(file_ids))
        query = f"""SELECT file_id, status FROM File
                 WHERE deleted = 0 AND file_id IN ({placeholders})
                 AND kb_id = ? AND kb_id IN (SELECT kb_id FROM KnowledgeBase WHERE user_id = ?)"""
        return self._execute(query, tuple(file_ids) + (kb_id, user_id), fetch=True)

    def check_file_exist_by_name(self, user_id, kb_id, file_names):
        results = []
        batch_size = 100
        for i in range(0, len(file_names), batch_size):
            batch = file_names[i:i + batch_size]
            placeholders = ','.join(['?'] * len(batch))
            query = f"""SELECT file_id, file_name, file_size, status FROM File
                     WHERE deleted = 0 AND file_name IN ({placeholders})
                     AND kb_id = ? AND kb_id IN (SELECT kb_id FROM KnowledgeBase WHERE user_id = ?)"""
            batch_result = self._execute(query, tuple(batch) + (kb_id, user_id), fetch=True)
            debug_logger.info("check_file_exist_by_name batch %d: %s", i // batch_size, batch_result)
            results.extend(batch_result)
        return results

    def get_files(self, user_id, kb_id):
        return self._execute(
            "SELECT file_id, file_name, status, file_size, content_length, timestamp FROM File WHERE kb_id = ? AND kb_id IN (SELECT kb_id FROM KnowledgeBase WHERE user_id = ?) AND deleted = 0",
            (kb_id, user_id), fetch=True
        )

    def get_file_download_info(self, file_id):
        """Look up download info (user_id, file_name, deleted) by file_id."""
        query = """
            SELECT u.user_id, f.file_name, f.deleted
            FROM File f
            JOIN KnowledgeBase kb ON f.kb_id = kb.kb_id
            JOIN User u ON kb.user_id = u.user_id
            WHERE f.file_id = ?
        """
        return self._execute(query, (file_id,), fetch=True)

    def delete_files(self, kb_id, file_ids):
        if not file_ids:
            return
        placeholders = ','.join(['?'] * len(file_ids))
        query = f"UPDATE File SET deleted = 1 WHERE kb_id = ? AND file_id IN ({placeholders})"
        self._execute(query, (kb_id,) + tuple(file_ids), commit=True)
        debug_logger.info("delete_files: %s", file_ids)

    def from_status_to_status(self, file_ids, from_status, to_status):
        if not file_ids:
            return
        placeholders = ','.join(['?'] * len(file_ids))
        query = f"UPDATE File SET status = ? WHERE file_id IN ({placeholders}) AND status = ?"
        self._execute(query, (to_status,) + tuple(file_ids) + (from_status,), commit=True)

    # ---- FTS5 full-text search (disabled by default; interface reserved) ----
    def insert_fts_chunks(self, file_id, file_name, chunks):
        """Insert document chunks into FTS5."""
        for idx, chunk in enumerate(chunks):
            chunk_id = f'{file_id}_{idx}'
            try:
                self._execute(
                    "INSERT INTO FileChunkFTS (content, file_id, file_name, chunk_id) VALUES (?, ?, ?, ?)",
                    (chunk, file_id, file_name, chunk_id), commit=True
                )
            except Exception as e:
                debug_logger.warning("FTS insert failed: %s", e)
                return False
        return True

    def search_fts(self, query, limit=50):
        """Search the FTS5 full-text index."""
        try:
            result = self._execute(
                "SELECT content, file_id, file_name, chunk_id FROM FileChunkFTS WHERE FileChunkFTS MATCH ? LIMIT ?",
                (query, limit), fetch=True
            )
            return result
        except Exception as e:
            debug_logger.warning("FTS search failed: %s", e)
            return []

    def delete_fts_chunks(self, file_ids):
        """Delete FTS5 chunks for the given files."""
        if not file_ids:
            return
        placeholders = ','.join(['?'] * len(file_ids))
        try:
            self._execute(
                f"DELETE FROM FileChunkFTS WHERE file_id IN ({placeholders})",
                tuple(file_ids), commit=True
            )
        except Exception as e:
            debug_logger.warning("FTS delete failed: %s", e)
