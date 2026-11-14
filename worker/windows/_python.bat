@echo off
rem Define PYEXE: usa o ambiente .venv se existir; senao o Python registrado na instalacao.
set "PYEXE="
if exist "%~dp0..\.venv\Scripts\python.exe" set "PYEXE=%~dp0..\.venv\Scripts\python.exe"
if not defined PYEXE if exist "%~dp0..\pyexe.txt" set /p PYEXE=<"%~dp0..\pyexe.txt"
if not defined PYEXE (
  echo Worker ainda nao instalado. Rode primeiro 1-instalar.bat
  pause
  exit /b 1
)
exit /b 0
