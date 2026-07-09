@echo off
REM Bishon V2 - Start knowledge base service on port 8777

cd /d %~dp0

REM Activate conda environment
REM Adjust the conda path below to match your install location.
where conda >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    REM Try common install locations
    if exist "%USERPROFILE%\miniconda3\Scripts\activate.bat" (
        call "%USERPROFILE%\miniconda3\Scripts\activate.bat" bishon
    ) else if exist "C:\ProgramData\miniconda3\Scripts\activate.bat" (
        call "C:\ProgramData\miniconda3\Scripts\activate.bat" bishon
    ) else (
        echo [ERROR] Conda not found. Please install Miniconda/Anaconda or update this script.
        pause
        exit /b 1
    )
) else (
    call conda activate bishon
)
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Failed to activate conda env "bishon"
    pause
    exit /b 1
)
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Failed to activate conda env "bishon"
    pause
    exit /b 1
)

REM Ensure directories exist
if not exist logs\debug_logs mkdir logs\debug_logs
if not exist logs\qa_logs mkdir logs\qa_logs
if not exist BISHON_DB\faiss mkdir BISHON_DB\faiss
if not exist BISHON_DB\content mkdir BISHON_DB\content

REM One-time dependency install
if not exist .deps_installed (
    echo [INFO] Installing Python dependencies...
    pip install -r requirements.txt
    if %ERRORLEVEL% EQU 0 (
        type nul > .deps_installed
    ) else (
        echo [ERROR] pip install failed. Run manually: pip install -r requirements.txt
        pause
        exit /b 1
    )
)

REM Kill any previous process on port 8777
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8777.*LISTENING"') do (
    echo [INFO] Port 8777 is in use by PID %%a, killing...
    taskkill /F /PID %%a >nul 2>&1
    timeout /t 2 /nobreak >nul
)

echo [INFO] Starting Bishon V2 on http://localhost:8777 ...
python bishon_kernel\bishon_server\app.py
pause
