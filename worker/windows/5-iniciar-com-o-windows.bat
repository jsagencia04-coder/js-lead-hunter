@echo off
chcp 65001 >nul
title JS Lead Hunter - Iniciar com o Windows
echo Cria uma tarefa agendada para abrir o worker sempre que voce entrar no Windows.
schtasks /create /tn "JS Lead Hunter Worker" /sc onlogon /rl limited /f /tr "\"%~dp03-iniciar-worker.bat\"" && (
  echo Pronto. Para remover: schtasks /delete /tn "JS Lead Hunter Worker" /f
)
pause
