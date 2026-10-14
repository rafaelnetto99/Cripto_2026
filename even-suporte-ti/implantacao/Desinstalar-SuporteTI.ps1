#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Arquivo : implantacao\Desinstalar-SuporteTI.ps1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Remove a pasta da aplicação, o atalho e a chave de registro de versão.
    NÃO remove credenciais salvas, impressoras instaladas nem logs dos
    usuários (%LOCALAPPDATA%\EVEN\SuporteTI) — ver LEIA-ME, Etapa 6, item 8.
    Códigos de saída: 0 = ok; 1 = falha.
#>
[CmdletBinding()]
param(
    [string]$Destino = (Join-Path $env:ProgramFiles 'EVEN\SuporteTI')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    # Trava de segurança: só apaga a pasta esperada da aplicação
    $alvo = [IO.Path]::GetFullPath($Destino).TrimEnd('\')
    if ($alvo -notlike '*\EVEN\SuporteTI' -or -not (Test-Path -LiteralPath (Join-Path $alvo 'SuporteTI.ps1'))) {
        if (Test-Path -LiteralPath $alvo) { throw ('Pasta não reconhecida como instalação da ferramenta: {0}' -f $alvo) }
    }
    else {
        Remove-Item -LiteralPath $alvo -Recurse -Force
    }

    $atalho = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\EVEN\Central de Suporte TI.lnk'
    if (Test-Path -LiteralPath $atalho) { Remove-Item -LiteralPath $atalho -Force }
    $pastaAtalho = Split-Path -Parent $atalho
    if ((Test-Path -LiteralPath $pastaAtalho) -and -not (Get-ChildItem -LiteralPath $pastaAtalho -Force)) { Remove-Item -LiteralPath $pastaAtalho -Force }

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\EVEN\SuporteTI') { Remove-Item -LiteralPath 'HKLM:\SOFTWARE\EVEN\SuporteTI' -Recurse -Force }

    Write-Output 'Central de Suporte TI removida.'
    exit 0
}
catch {
    Write-Error ('Falha na desinstalação: {0}' -f $_.Exception.Message) -ErrorAction Continue
    exit 1
}
