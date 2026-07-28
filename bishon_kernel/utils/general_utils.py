"""Bishon V2 common utilities — FastAPI-compatible."""
import functools
import logging
import os
import re
import time

try:
    import tiktoken
    HAS_TIKTOKEN = True
except ImportError:
    HAS_TIKTOKEN = False

__all__ = ['write_check_file', 'format_source_documents', 'get_time',
           'truncate_filename', 'validate_user_id',
           'get_invalid_user_id_msg', 'num_tokens', 'current_timestamp']


def get_invalid_user_id_msg(user_id):
    return f"fail, Invalid user_id: {user_id}. user_id 必须只含有字母，数字和下划线且字母开头"


def current_timestamp() -> str:
    from datetime import datetime
    return datetime.now().strftime("%Y%m%d%H%M")


def write_check_file(filepath, docs):
    folder_path = os.path.join(os.path.dirname(filepath), "tmp_files")
    os.makedirs(folder_path, exist_ok=True)
    fp = os.path.join(folder_path, 'load_file.txt')
    with open(fp, 'a+', encoding='utf-8') as fout:
        fout.write(f"filepath={filepath},len={len(docs)}\n")
        for i in docs:
            fout.write(str(i) + '\n')


def format_source_documents(ori_source_documents):
    """Format source documents into the API response shape (preserves the legacy interface)."""
    source_documents = []
    for doc in ori_source_documents:
        metadata = doc.metadata
        source_info = {
            'file_id': metadata.get('file_id', ''),
            'file_name': metadata.get('file_name', ''),
            'content': doc.page_content,
            'retrieval_query': metadata.get('retrieval_query', ''),
            'kernel': metadata.get('kernel', doc.page_content),
            'score': metadata.get('score', 0),
            'embed_version': metadata.get('embed_version', 'v2'),
        }
        source_documents.append(source_info)
    return source_documents


def get_time(func):
    @functools.wraps(func)
    def inner(*arg, **kwargs):
        s_time = time.time()
        res = func(*arg, **kwargs)
        if hasattr(res, '__iter__') and hasattr(res, '__next__'):
            # Generator: wrap to time full exhaustion
            def timed_gen():
                try:
                    yield from res
                finally:
                    e_time = time.time()
                    logging.info('%s executed in %.2f seconds', func.__name__, e_time - s_time)
            return timed_gen()
        e_time = time.time()
        logging.info('%s executed in %.2f seconds', func.__name__, e_time - s_time)
        return res
    return inner


def truncate_filename(filename, max_length=200):
    file_ext = os.path.splitext(filename)[1]
    file_name_no_ext = os.path.splitext(filename)[0]
    filename_length = len(filename.encode('utf-8'))

    if filename_length > max_length:
        timestamp = str(int(time.time()))
        while filename_length > max_length:
            file_name_no_ext = file_name_no_ext[:-4]
            new_filename = file_name_no_ext + "_" + timestamp + file_ext
            filename_length = len(new_filename.encode('utf-8'))
    else:
        new_filename = filename
    return new_filename


def validate_user_id(user_id):
    pattern = r'^[A-Za-z][A-Za-z0-9_]*$'
    return isinstance(user_id, str) and bool(re.match(pattern, user_id))


def num_tokens(text: str, model: str = 'gpt-3.5-turbo-0613') -> int:
    if HAS_TIKTOKEN:
        encoding = tiktoken.encoding_for_model(model)
        return len(encoding.encode(text))
    return len(text) // 4
