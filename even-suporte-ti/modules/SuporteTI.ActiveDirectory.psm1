<#
    Arquivo : modules\SuporteTI.ActiveDirectory.psm1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Console "Usuários e Computadores do Active Directory" (dsa.msc):
      - verificação do RSAT (arquivos do console + capacidade do Windows);
      - abertura direcionada a um controlador de domínio (/server=);
      - instalação do RSAT (somente administrador, processo elevado).
#>
Set-StrictMode -Version 2.0

function Get-CaminhosConsoleAD {
    $sistema = Get-CaminhoSistema
    return [pscustomobject]@{
        Sistema = $sistema
        Dsa     = (Join-Path $sistema 'dsa.msc')
        DsAdmin = (Join-Path $sistema 'dsadmin.dll')
        Mmc     = (Join-Path $sistema 'mmc.exe')
    }
}

function Test-RsatAD {
    <#
        O console precisa do .msc E da DLL do snap-in. Só o .msc (teste da
        BAT) não garante que o console abra. Não exige administrador.
    #>
    $c = Get-CaminhosConsoleAD
    $temMsc = Test-Path -LiteralPath $c.Dsa -PathType Leaf
    $temDll = Test-Path -LiteralPath $c.DsAdmin -PathType Leaf
    return [pscustomobject]@{
        Instalado = ($temMsc -and $temDll)
        Detalhe   = ('dsa.msc={0}; dsadmin.dll={1}; pasta={2}' -f $temMsc, $temDll, $c.Sistema)
    }
}

function Open-ConsoleAD {
    <#
        Abre o dsa.msc apontando para o servidor. O nome do servidor vem da
        configuração validada (Test-NomeHost) — não há entrada livre.
        -Credencial: abre o console como outro usuário (modo OutroUsuario).
    #>
    param(
        [Parameter(Mandatory)][string]$Servidor,
        [System.Management.Automation.PSCredential]$Credencial = $null
    )
    if (-not (Test-NomeHost $Servidor)) { throw ('Nome de servidor inválido: {0}' -f $Servidor) }
    $c = Get-CaminhosConsoleAD
    $argumentos = @(('"{0}"' -f $c.Dsa), ('/server={0}' -f $Servidor))

    if ($Credencial) {
        $processo = Start-Process -FilePath $c.Mmc -ArgumentList $argumentos -Credential $Credencial `
            -LoadUserProfile -WorkingDirectory $c.Sistema -PassThru -ErrorAction Stop
    }
    else {
        $processo = Start-Process -FilePath $c.Mmc -ArgumentList $argumentos -WorkingDirectory $c.Sistema -PassThru -ErrorAction Stop
    }

    # Confere se o console não fechou logo em seguida com erro.
    Start-Sleep -Seconds 3
    $encerrou = $false
    $codigoSaida = $null
    try {
        $encerrou = $processo.HasExited
        if ($encerrou) { $codigoSaida = $processo.ExitCode }
    }
    catch { $encerrou = $false }   # processo de outro usuário: sem acesso ao estado — segue

    if ($encerrou -and $codigoSaida -ne 0) {
        return [pscustomobject]@{ Ok = $false; Detalhe = ('mmc.exe encerrou com código {0}' -f $codigoSaida) }
    }
    return [pscustomobject]@{ Ok = $true; Detalhe = ('mmc.exe iniciado (PID {0})' -f $processo.Id) }
}

function Install-RsatAD {
    <# Instala a capacidade RSAT AD DS/LDS (Windows 10 1809+ / 11). Exige elevação e acesso ao Windows Update/WSUS. #>
    if (-not (Test-Administrador)) {
        return New-ResultadoAcao -Status Falha -Mensagem 'A instalação do RSAT exige administrador.' -Elevacao 'Negada'
    }
    if (-not (Get-Command -Name Get-WindowsCapability -ErrorAction SilentlyContinue)) {
        return New-ResultadoAcao -Status Falha -Mensagem 'Esta versão do Windows não instala o RSAT por "Recursos opcionais".' `
            -Recomendacao 'Instale o pacote RSAT correspondente à versão do Windows (download Microsoft).' -Elevacao 'Elevado'
    }

    Send-Progresso -Texto 'Consultando recursos opcionais do Windows...'
    $capacidade = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.Name -like 'Rsat.ActiveDirectory.DS-LDS.Tools*' }) | Select-Object -First 1
    if (-not $capacidade) {
        return New-ResultadoAcao -Status Falha -Mensagem 'O RSAT do Active Directory não foi encontrado nos recursos opcionais deste Windows.' -Elevacao 'Elevado'
    }
    if ([string]$capacidade.State -eq 'Installed') {
        return New-ResultadoAcao -Status Sucesso -Mensagem 'O RSAT do Active Directory já está instalado.' -Elevacao 'Elevado'
    }

    Send-Progresso -Texto 'Instalando RSAT (pode levar vários minutos)...'
    $retorno = Add-WindowsCapability -Online -Name $capacidade.Name -ErrorAction Stop
    $depois = Get-WindowsCapability -Online -Name $capacidade.Name -ErrorAction Stop
    if ([string]$depois.State -ne 'Installed') {
        return New-ResultadoAcao -Status Falha -Mensagem 'O Windows não concluiu a instalação do RSAT.' `
            -Recomendacao 'Verifique se o computador acessa o Windows Update/WSUS para "Recursos sob demanda".' `
            -Detalhes ('Estado após instalação: {0}' -f $depois.State) -Elevacao 'Elevado'
    }
    $msg = 'RSAT do Active Directory instalado.'
    if ($retorno -and $retorno.RestartNeeded) { $msg += ' Reinicie o computador para concluir.' }
    return New-ResultadoAcao -Status Sucesso -Mensagem $msg -Elevacao 'Elevado'
}

Export-ModuleMember -Function *
