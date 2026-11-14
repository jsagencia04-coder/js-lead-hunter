@echo off
chcp 65001 >nul
title JS Lead Hunter - Instalacao do worker
cd /d "%~dp0.."
echo ============================================================
echo  JS Lead Hunter - instalacao do worker de importacao
echo ============================================================
set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY where python >nul 2>nul && set "PY=python"
if not defined PY (
  echo.
  echo Python nao encontrado. Instale o Python 3.12 ou superior:
  echo   https://www.python.org/downloads/windows/
  echo Na instalacao, marque "Add python.exe to PATH". Depois rode este arquivo de novo.
  pause
  exit /b 1
)
%PY% -c "import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)" || (
  echo Python muito antigo. Instale o Python 3.12 ou superior e rode de novo.
  pause
  exit /b 1
)
if not exist ".venv\Scripts\python.exe" (
  echo Criando ambiente Python em %cd%\.venv ...
  %PY% -m venv .venv || (echo Falha ao criar o ambiente. & pause & exit /b 1)
)
echo Instalando dependencias (DuckDB, Polars, psycopg...)...
".venv\Scripts\python.exe" -m pip install --upgrade pip >nul
".venv\Scripts\python.exe" -m pip install -r requirements.txt || (echo Falha na instalacao. & pause & exit /b 1)
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
