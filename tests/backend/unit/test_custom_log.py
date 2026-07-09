"""Tests for daily log-rotation configuration."""
import logging
from logging.handlers import TimedRotatingFileHandler

from bishon_kernel.utils.custom_log import (
    DEBUG_BACKUP_DAYS,
    QA_BACKUP_DAYS,
    debug_logger,
    qa_logger,
)


class TestLoggerInstances:
    def test_debug_logger_is_logger(self):
        assert isinstance(debug_logger, logging.Logger)
        assert debug_logger.name == 'debug_logger'

    def test_qa_logger_is_logger(self):
        assert isinstance(qa_logger, logging.Logger)
        assert qa_logger.name == 'qa_logger'

    def test_loggers_at_info_level(self):
        assert debug_logger.level == logging.INFO
        assert qa_logger.level == logging.INFO


class TestHandlerConfiguration:
    def test_debug_handler_is_timed_rotating(self):
        handlers = [h for h in debug_logger.handlers if isinstance(h, TimedRotatingFileHandler)]
        assert len(handlers) == 1

    def test_qa_handler_is_timed_rotating(self):
        handlers = [h for h in qa_logger.handlers if isinstance(h, TimedRotatingFileHandler)]
        assert len(handlers) == 1

    def test_debug_handler_midnight_rotation(self):
        handler = next(h for h in debug_logger.handlers if isinstance(h, TimedRotatingFileHandler))
        assert handler.when == 'MIDNIGHT'

    def test_qa_handler_midnight_rotation(self):
        handler = next(h for h in qa_logger.handlers if isinstance(h, TimedRotatingFileHandler))
        assert handler.when == 'MIDNIGHT'

    def test_debug_backup_count(self):
        handler = next(h for h in debug_logger.handlers if isinstance(h, TimedRotatingFileHandler))
        assert handler.backupCount == DEBUG_BACKUP_DAYS

    def test_qa_backup_count(self):
        handler = next(h for h in qa_logger.handlers if isinstance(h, TimedRotatingFileHandler))
        assert handler.backupCount == QA_BACKUP_DAYS

    def test_debug_log_file_path(self):
        handler = next(h for h in debug_logger.handlers if isinstance(h, TimedRotatingFileHandler))
        assert handler.baseFilename.endswith('debug.log')

    def test_qa_log_file_path(self):
        handler = next(h for h in qa_logger.handlers if isinstance(h, TimedRotatingFileHandler))
        assert handler.baseFilename.endswith('qa.log')


class TestLoggingWorks:
    def test_debug_logger_writes(self, tmp_path):
        log_file = str(tmp_path / "test_debug.log")
        handler = TimedRotatingFileHandler(log_file, when='midnight', backupCount=3, encoding='utf-8')
        handler.setFormatter(logging.Formatter("%(message)s"))
        test_logger = logging.getLogger('test_debug_write')
        test_logger.setLevel(logging.INFO)
        test_logger.addHandler(handler)
        test_logger.info("test message")
        handler.flush()
        with open(log_file, encoding='utf-8') as f:
            content = f.read()
        assert "test message" in content
        test_logger.removeHandler(handler)
        handler.close()
