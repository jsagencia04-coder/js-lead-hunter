@echo off
chcp 65001 >nul
title JS Lead Hunter - Instalacao do worker
cd /d "%~dp0.."
set "LOG=%~dp0instalar-log.txt"
echo Instalacao iniciada em %date% %time% > "%LOG%"
echo ============================================================
echo  JS Lead Hunter - instalacao do worker de importacao
echo  (registro completo em windows\instalar-log.txt)
echo ============================================================
set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY where python >nul 2>nul && set "PY=python"
if not defined PY (
  echo Python nao encontrado. >> "%LOG%"
  echo.
  echo Python nao encontrado. Instale o Python 3.12 ou superior:
  echo   https://www.python.org/downloads/windows/
  echo Na instalacao, marque "Add python.exe to PATH". Depois rode este arquivo de novo.
  pause
  exit /b 1
)
%PY% -c "import sys; print(sys.executable, sys.version)" >> "%LOG%" 2>&1
%PY% -c "import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)" || (
  echo Python muito antigo. Instale o Python 3.12 ou superior e rode de novo.
  echo Python antigo >> "%LOG%"
  pause
  exit /b 1
)
if exist "pyexe.txt" del "pyexe.txt"

rem 1a tentativa: ambiente virtual isolado (.venv)
if not exist ".venv\Scripts\python.exe" (
  echo Criando ambiente Python em %cd%\.venv ...
  %PY% -m venv .venv >> "%LOG%" 2>&1
)
if exist ".venv\Scripts\python.exe" (
  set "PYEXE=%cd%\.venv\Scripts\python.exe"
  echo Ambiente virtual criado. >> "%LOG%"
  goto deps
)

rem 2a tentativa: sem ambiente virtual, instalando no usuario atual
echo Nao foi possivel criar o ambiente virtual; instalando direto no Python do usuario.
echo venv falhou; usando instalacao --user >> "%LOG%"
if exist ".venv" rmdir /s /q ".venv" >nul 2>nul
for /f "usebackq delims=" %%i in (`%PY% -c "import sys; print(sys.executable)"`) do set "PYEXE=%%i"
> "pyexe.txt" echo %PYEXE%
set "PIPUSER=--user"

:deps
echo Python usado: %PYEXE% >> "%LOG%"
echo Instalando dependencias (DuckDB, Polars, psycopg...)...
"%PYEXE%" -m ensurepip --upgrade >> "%LOG%" 2>&1
"%PYEXE%" -m pip install %PIPUSER% --upgrade pip >> "%LOG%" 2>&1
"%PYEXE%" -m pip install %PIPUSER% -r requirements.txt >> "%LOG%" 2>&1
if errorlevel 1 (
  echo FALHA na instalacao das dependencias >> "%LOG%"
  echo Falha ao instalar as dependencias. Veja windows\instalar-log.txt
  pause
  exit /b 1
)
"%PYEXE%" -c "import duckdb, polars, psycopg, httpx; print('dependencias OK')" >> "%LOG%" 2>&1 || (
  echo Dependencias nao carregaram. Veja windows\instalar-log.txt
  pause
  exit /b 1
)
echo INSTALACAO_OK >> "%LOG%"
if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo.
  echo Criei o arquivo .env. Ele vai abrir no Bloco de Notas:
  echo preencha a linha DATABASE_URL com a conexao do Supabase, salve e feche.
  notepad ".env"
)
echo.
echo Instalacao concluida. Proximo passo: 2-verificar-receita.bat
pause
