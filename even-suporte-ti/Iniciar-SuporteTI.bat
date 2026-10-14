@echo off
rem ==================================================================
rem  Central de Suporte TI - EVEN - inicializador (OPCIONAL)
rem  Arquivo: Iniciar-SuporteTI.bat
rem
rem  Prefira o atalho criado na instalacao (ver docs). Este .bat existe
rem  so por conveniencia/compatibilidade com o fluxo antigo.
rem
rem  - NAO usa "-ExecutionPolicy Bypass": os scripts devem estar
rem    assinados e a politica definida por GPO/Intune (AllSigned ou
rem    RemoteSigned). Se a politica bloquear, a mensagem aparece aqui.
rem  - Nao recebe parametros e nao repassa nada digitado pelo usuario.
rem  - Usa o PowerShell 64 bits mesmo se chamado de um processo 32 bits.
rem ==================================================================
setlocal
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

"%PSEXE%" -NoProfile -NoLogo -STA -File "%~dp0SuporteTI.ps1"
set "CODIGO=%ERRORLEVEL%"

rem Codigo 1 = o PowerShell nem chegou a abrir a ferramenta (ex.: politica
rem de execucao ou assinatura). Os demais erros ja sao mostrados em janela.
if "%CODIGO%"=="1" (
    echo.
    echo Nao foi possivel iniciar a Central de Suporte TI.
    echo Provavel causa: politica de execucao de scripts ou script sem assinatura valida.
    echo Informe esta mensagem a equipe de TI.
    echo.
    pause
)
endlocal & exit /b %CODIGO%
