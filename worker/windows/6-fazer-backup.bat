@echo off
chcp 65001 >nul
title JS Lead Hunter - Backup do banco
cd /d "%~dp0.."
call "%~dp0_python.bat" || exit /b 1
echo Gera um backup completo e verificado do banco na pasta "backups" (ao lado do worker).
echo O backup contem dados pessoais: guarde em local protegido e NAO envie ao GitHub.
echo.
"%PYEXE%" -m lead_hunter backup %1
pause
