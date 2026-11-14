@echo off
chcp 65001 >nul
title JS Lead Hunter - Worker (deixe esta janela aberta)
cd /d "%~dp0.."
call "%~dp0_python.bat" || exit /b 1
if not exist ".env" (echo Arquivo .env nao encontrado. Rode 1-instalar.bat & pause & exit /b 1)
echo ============================================================
echo  Worker do JS Lead Hunter em execucao.
echo  - Atende os botoes da Central de importacao do sistema.
echo  - Verifica nova competencia da Receita a cada 12 horas.
echo  Deixe esta janela aberta. Para parar: feche a janela.
echo ============================================================
:loop
"%PYEXE%" -m lead_hunter run
echo.
echo O worker parou (codigo %errorlevel%). Reiniciando em 60 segundos... (feche a janela para encerrar)
timeout /t 60 >nul
goto loop
