@echo off
chcp 65001 >nul
title JS Lead Hunter - Importacao manual
cd /d "%~dp0.."
if not exist ".venv\Scripts\python.exe" (echo Rode primeiro 1-instalar.bat & pause & exit /b 1)
echo Importa agora a competencia mais recente da Receita Federal.
echo Pode levar varias horas (o servidor da Receita e lento). Nao desligue o computador.
echo Se o download for interrompido, rode de novo: ele continua de onde parou.
echo.
".venv\Scripts\python.exe" -m lead_hunter import %1
pause
