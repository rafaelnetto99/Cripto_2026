#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Arquivo : implantacao\Instalar-SuporteTI.ps1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Instala a ferramenta em C:\Program Files\EVEN\SuporteTI (pasta onde só
    administradores gravam), cria o atalho no Menu Iniciar de todos os
    usuários e registra a versão para detecção (Intune/SCCM).

    Uso (como Sistema ou administrador, a partir da pasta do pacote):
      powershell.exe -NoProfile -File .\implantacao\Instalar-SuporteTI.ps1

    O pacote deve conter tudo que vai para a máquina (inclusive assets\logo.png):
    a cópia espelha a pasta do pacote (arquivos que não estão no pacote são
    removidos do destino).
    Códigos de saída: 0 = ok; 1 = falha.
#>
[CmdletBinding()]
param(
    [string]$Destino = (Join-Path $env:ProgramFiles 'EVEN\SuporteTI')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    $origem = Split-Path -Parent $PSScriptRoot
    foreach ($obrigatorio in 'SuporteTI.ps1', 'SuporteTI.Elevado.ps1', 'ui\MainWindow.xaml', 'config\SuporteTI.config.psd1') {
        if (-not (Test-Path -LiteralPath (Join-Path $origem $obrigatorio) -PathType Leaf)) {
            throw ('Arquivo obrigatório ausente no pacote: {0}' -f $obrigatorio)
        }
    }

    # Cópia espelhada (robocopy: códigos < 8 = sucesso)
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $proc = Start-Process -FilePath $robocopy -ArgumentList @(('"{0}"' -f $origem), ('"{0}"' -f $Destino), '/MIR', '/R:2', '/W:2', '/NP', '/NFL', '/NDL') -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ge 8) { throw ('robocopy falhou com código {0}' -f $proc.ExitCode) }

    # Desbloqueia arquivos baixados (marca da internet), se houver
    Get-ChildItem -LiteralPath $Destino -Recurse -File | Unblock-File

    # Atalho no Menu Iniciar (todos os usuários)
    $pastaAtalho = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\EVEN'
    New-Item -ItemType Directory -Path $pastaAtalho -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $atalho = $shell.CreateShortcut((Join-Path $pastaAtalho 'Central de Suporte TI.lnk'))
    $atalho.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $atalho.Arguments = ('-NoProfile -NoLogo -STA -WindowStyle Hidden -File "{0}"' -f (Join-Path $Destino 'SuporteTI.ps1'))
    $atalho.WorkingDirectory = $Destino
    $atalho.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',109'
    $atalho.Description = 'Central de Suporte TI - EVEN'
    $atalho.Save()

    # Versão para regra de detecção
    $config = Import-PowerShellDataFile -LiteralPath (Join-Path $Destino 'config\SuporteTI.config.psd1')
    $chave = 'HKLM:\SOFTWARE\EVEN\SuporteTI'
    New-Item -Path $chave -Force | Out-Null
    New-ItemProperty -Path $chave -Name 'Versao' -Value ([string]$config.Aplicacao.Versao) -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $chave -Name 'Pasta' -Value $Destino -PropertyType String -Force | Out-Null

    Write-Output ('Central de Suporte TI {0} instalada em {1}' -f $config.Aplicacao.Versao, $Destino)
    exit 0
}
catch {
    Write-Error ('Falha na instalação: {0}' -f $_.Exception.Message) -ErrorAction Continue
    exit 1
}
