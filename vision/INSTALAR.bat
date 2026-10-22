@echo off
cd /d "%~dp0"
echo Instalando el sistema de vision del robot...
echo (Necesita internet. Tarda unos 5-15 minutos la primera vez.)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar.ps1"
if errorlevel 1 (
  echo.
  echo *** Hubo un error. Lee el mensaje de arriba. ***
)
pause
