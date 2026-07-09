import logging
import os
from logging.handlers import TimedRotatingFileHandler

from bishon_kernel.configs.model_config import root_path

DEBUG_BACKUP_DAYS  = 30
QA_BACKUP_DAYS     = 60

debug_log_folder = os.path.join(root_path, 'logs', 'debug_logs')
qa_log_folder    = os.path.join(root_path, 'logs', 'qa_logs')

if not os.path.exists(debug_log_folder):
    os.makedirs(debug_log_folder)
if not os.path.exists(qa_log_folder):
    os.makedirs(qa_log_folder)

qa_logger    = logging.getLogger('qa_logger')
debug_logger = logging.getLogger('debug_logger')
qa_logger.setLevel(logging.INFO)
debug_logger.setLevel(logging.INFO)

# Compat for the uvicorn worker environment
if 'UVICORN_WORKER_ID' in os.environ:
    process_type = f'Worker-{os.environ["UVICORN_WORKER_ID"]}'
elif 'SANIC_WORKER_NAME' in os.environ:
    process_type = os.environ['SANIC_WORKER_NAME']
else:
    process_type = 'MainProcess'

debug_handler = TimedRotatingFileHandler(
    os.path.join(debug_log_folder, "debug.log"),
    when='midnight', interval=1, backupCount=DEBUG_BACKUP_DAYS, encoding='utf-8',
)
debug_formatter = logging.Formatter(
    f"%(asctime)s - [PID: %(process)d][{process_type}] - "
    f"[Function: %(funcName)s] - %(levelname)s - %(message)s"
)
debug_handler.setFormatter(debug_formatter)
debug_logger.addHandler(debug_handler)

qa_handler = TimedRotatingFileHandler(
    os.path.join(qa_log_folder, "qa.log"),
    when='midnight', interval=1, backupCount=QA_BACKUP_DAYS, encoding='utf-8',
)
qa_formatter = logging.Formatter("%(asctime)s %(message)s")
qa_handler.setFormatter(qa_formatter)
qa_logger.addHandler(qa_handler)
