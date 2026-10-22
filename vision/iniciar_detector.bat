@echo off
cd /d "%~dp0"
.venv\Scripts\python.exe detectar_fuego.py %*
pause
