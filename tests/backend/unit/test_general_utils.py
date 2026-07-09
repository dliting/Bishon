"""Tests for pure functions in general_utils."""
import logging

from bishon_kernel.utils.general_utils import (
    format_source_documents,
    get_time,
    num_tokens,
    truncate_filename,
    validate_user_id,
)


class TestValidateUserId:
    def test_valid_simple(self):
        assert validate_user_id("abc123") is True

    def test_valid_with_underscore(self):
        assert validate_user_id("A_b") is True

    def test_valid_single_letter(self):
        assert validate_user_id("Z") is True

    def test_valid_uppercase_start(self):
        assert validate_user_id("Z_0") is True

    def test_invalid_number_start(self):
        assert validate_user_id("123abc") is False

    def test_invalid_hyphen(self):
        assert validate_user_id("a-b") is False

    def test_invalid_empty_string(self):
        assert validate_user_id("") is False

    def test_invalid_none(self):
        assert validate_user_id(None) is False

    def test_invalid_special_chars(self):
        assert validate_user_id("a@b") is False

    def test_invalid_space(self):
        assert validate_user_id("a b") is False

    def test_invalid_pure_number(self):
        assert validate_user_id("12345") is False

    def test_invalid_non_string_type(self):
        assert validate_user_id(123) is False

    def test_long_valid(self):
        assert validate_user_id("a" * 256) is True


class TestTruncateFilename:
    def test_short_unchanged(self):
        assert truncate_filename("a.txt") == "a.txt"

    def test_exactly_at_limit(self):
        name = "a" * 190 + ".txt"
        assert truncate_filename(name) == name

    def test_long_truncated(self):
        long_name = "a" * 250 + ".txt"
        result = truncate_filename(long_name, max_length=200)
        assert len(result.encode("utf-8")) <= 200
        assert result.endswith(".txt")

    def test_chinese_filename(self):
        name = "测试" * 50 + ".pdf"
        result = truncate_filename(name, max_length=200)
        assert len(result.encode("utf-8")) <= 200
        assert result.endswith(".pdf")

    def test_no_extension(self):
        name = "a" * 250
        result = truncate_filename(name, max_length=200)
        assert len(result.encode("utf-8")) <= 200

    def test_dotfile(self):
        assert truncate_filename(".gitignore") == ".gitignore"


class TestFormatSourceDocuments:
    def test_empty_list(self):
        assert format_source_documents([]) == []

    def test_single_document(self):
        from langchain_core.documents import Document
        doc = Document(
            page_content="hello",
            metadata={"file_id": "f1", "file_name": "test.txt", "score": 0.5}
        )
        result = format_source_documents([doc])
        assert len(result) == 1
        assert result[0]["file_id"] == "f1"
        assert result[0]["content"] == "hello"
        assert result[0]["score"] == 0.5

    def test_missing_metadata_fields(self):
        from langchain_core.documents import Document
        doc = Document(page_content="hello", metadata={})
        result = format_source_documents([doc])
        assert result[0]["file_id"] == ""
        assert result[0]["score"] == 0

    def test_multiple_documents(self):
        from langchain_core.documents import Document
        docs = [
            Document(page_content=f"text{i}", metadata={"file_id": f"f{i}"})
            for i in range(3)
        ]
        result = format_source_documents(docs)
        assert len(result) == 3


class TestNumTokens:
    def test_returns_positive(self):
        assert num_tokens("hello world") > 0

    def test_empty_string(self):
        assert num_tokens("") == 0

    def test_longer_text_more_tokens(self):
        assert num_tokens("a" * 1000) > num_tokens("a" * 10)


class TestGetTime:
    def test_regular_function(self, caplog):
        @get_time
        def add(a, b):
            return a + b

        with caplog.at_level(logging.INFO):
            result = add(1, 2)
        assert result == 3
        assert 'add' in caplog.text
        assert 'executed in' in caplog.text

    def test_preserves_function_name(self):
        @get_time
        def my_func():
            pass

        assert my_func.__name__ == 'my_func'

    def test_generator_function_times_full_exhaustion(self, caplog):
        @get_time
        def gen():
            yield 1
            yield 2
            yield 3

        with caplog.at_level(logging.INFO):
            g = gen()
            # No log yet — generator not started
            assert 'executed in' not in caplog.text
            values = list(g)

        assert values == [1, 2, 3]
        assert 'gen' in caplog.text
        assert 'executed in' in caplog.text

    def test_generator_closed_early_still_times(self, caplog):
        @get_time
        def gen():
            yield 10
            yield 20

        with caplog.at_level(logging.INFO):
            g = gen()
            next(g)
            g.close()

        assert 'gen' in caplog.text
        assert 'executed in' in caplog.text
