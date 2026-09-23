@echo off
REM Lanzador de CrearAccesoDirecto.ps1: Windows no ejecuta los .ps1 con doble clic.
REM Pasa los argumentos tal cual: CrearAccesoDirecto.cmd -Escritorio -MenuInicio
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CrearAccesoDirecto.ps1" %*
echo.
pause
