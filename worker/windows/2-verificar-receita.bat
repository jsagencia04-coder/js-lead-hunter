@echo off
chcp 65001 >nul
title JS Lead Hunter - Verificar Receita Federal
cd /d "%~dp0.."
if not exist ".venv\Scripts\python.exe" (echo Rode primeiro 1-instalar.bat & pause & exit /b 1)
echo Consultando a competencia mais recente publicada pela Receita Federal...
".venv\Scripts\python.exe" -m lead_hunter check
pause
