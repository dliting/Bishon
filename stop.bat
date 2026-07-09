@echo off
REM Bishon V2 - Stop the knowledge base service

echo [INFO] Stopping Bishon V2...
set "FOUND="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8777.*LISTENING"') do (
    echo [INFO] Killing process PID %%a on port 8777...
    taskkill /F /PID %%a >nul 2>&1
    set FOUND=1
)
if not defined FOUND (
    echo [INFO] No process found on port 8777.
)
echo [SUCCESS] Bishon V2 stopped.
pause
