@echo off
chcp 65001 >nul
title JS Lead Hunter - Verificar Receita Federal
cd /d "%~dp0.."
call "%~dp0_python.bat" || exit /b 1
echo Consultando a competencia mais recente publicada pela Receita Federal...
"%PYEXE%" -m lead_hunter check > "%~dp0verificar-log.txt" 2>&1
type "%~dp0verificar-log.txt"
pause
