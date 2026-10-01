@echo off
title VibeGrab Server
cd /d "%~dp0backend"
echo ============================================
echo   VibeGrab Backend Server
echo   URL local:  http://localhost:8000
echo ============================================
echo.
for /f "tokens=1,2 delims=:" %%a in ('ipconfig ^| findstr /i "IPv4"') do echo   IP para el celular:%%b
echo.
echo   En la app: Ajustes - URL del backend = http://IP_DE_AQUI:8000
echo ============================================
echo.
"%~dp0backend\.venv\Scripts\uvicorn.exe" app.main:app --host 0.0.0.0 --port 8000
pause
