@echo off
REM Lanzador de Instalar.ps1: Windows no ejecuta los .ps1 con doble clic.
REM Pasa los argumentos tal cual: Instalar.cmd -Escritorio -MenuInicio
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar.ps1" %*
echo.
pause
