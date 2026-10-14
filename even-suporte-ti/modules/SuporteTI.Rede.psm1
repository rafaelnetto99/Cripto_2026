<#
    Arquivo : modules\SuporteTI.Rede.psm1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Conexões SMB e compartilhamentos de rede.
    Usa a API do Windows (WNetAddConnection2/WNetCancelConnection2) em
    vez de "net use": códigos de erro exatos, sem texto traduzido e sem
    passar credenciais na linha de comando.
#>
Set-StrictMode -Version 2.0

function Connect-RecursoRede {
    <# Conecta a \\servidor\recurso com as credenciais salvas. Retorna código Win32. #>
    param(
        [Parameter(Mandatory)][string]$Remoto,
        [string]$Letra = '',
        [switch]$Persistente
    )
    return [EvenSuporte.Nativo]::Conectar($Remoto, $Letra, [bool]$Persistente)
}

function Clear-SessoesServidor {
    <#
        Encerra conexões sem letra (IPC$ e caminhos abertos) com o servidor,
        para que a nova credencial seja usada. Unidades COM letra não são
        removidas (o usuário pode estar usando); apenas contadas.
    #>
    param([Parameter(Mandatory)][string]$Servidor)

    if (-not (Test-NomeHost $Servidor) -and -not (Test-EnderecoIPv4 $Servidor)) {
        throw ('Nome de servidor inválido: {0}' -f $Servidor)
    }

    $encerradas = 0
    $comLetra = 0
    $rc = [EvenSuporte.Nativo]::Desconectar(('\\{0}\IPC$' -f $Servidor), $true)
    if ($rc -eq 0) { $encerradas++ }

    if (Get-Command -Name Get-SmbMapping -ErrorAction SilentlyContinue) {
        $prefixo = '\\{0}\' -f $Servidor
        $mapeamentos = @(Get-SmbMapping -ErrorAction SilentlyContinue |
            Where-Object { $_.RemotePath -and $_.RemotePath.StartsWith($prefixo, [StringComparison]::OrdinalIgnoreCase) })
        foreach ($m in $mapeamentos) {
            if ([string]::IsNullOrEmpty($m.LocalPath)) {
                if ([EvenSuporte.Nativo]::Desconectar($m.RemotePath, $true) -eq 0) { $encerradas++ }
            }
            else {
                $comLetra++
            }
        }
    }
    return [pscustomobject]@{ Encerradas = $encerradas; UnidadesComLetra = $comLetra }
}

function Get-CompartilhamentosPermitidos {
    <# Compartilhamentos habilitados e liberados para o perfil. #>
    param([string]$Perfil = '')
    $ctx = Get-SuporteContexto
    if (-not $Perfil) { $Perfil = $ctx.Perfil }
    return @(@($ctx.Config.Compartilhamentos) | Where-Object { $_.Habilitado -and (@($_.Perfis) -contains $Perfil) })
}

function Open-Compartilhamento {
    <#
        Confere servidor (porta 445) e acesso à pasta, com timeout, mapeia a
        letra se configurada e abre no Explorador de Arquivos.
    #>
    param([Parameter(Mandatory)][hashtable]$Compartilhamento)

    $ctx = Get-SuporteContexto
    $nome = [string]$Compartilhamento.Nome
    $caminho = [string](Assert-ValorConfigurado -Valor $Compartilhamento.Caminho -Chave ('Compartilhamentos.{0}.Caminho' -f $Compartilhamento.Id))
    if (-not (Test-CaminhoUnc $caminho)) {
        return [pscustomobject]@{ Ok = $false; Texto = ('✖ {0}: caminho configurado inválido.' -f $nome); Detalhe = 'Caminho UNC inválido' }
    }
    $servidor = Get-ServidorDoCaminho $caminho

    Send-Progresso -Texto ('Verificando acesso a "{0}"...' -f $nome)
    $porta = Test-PortaTcp -Destino $servidor -Porta ([int]$ctx.Config.Rede.PortaSmb)
    if (-not $porta.Ok) {
        return [pscustomobject]@{
            Ok      = $false
            Texto   = ('✖ {0}: servidor de arquivos inacessível. Verifique a rede ou a VPN.' -f $nome)
            Detalhe = ('TCP {0}:445 -> {1}' -f $servidor, $porta.Motivo)
        }
    }

    $timeout = 8000
    if ($ctx.Config.Rede.ContainsKey('TimeoutAcessoPastaMs')) { $timeout = [int]$ctx.Config.Rede.TimeoutAcessoPastaMs }
    $acesso = Test-CaminhoRede -Caminho $caminho -TimeoutMs $timeout
    if (-not $acesso.Concluido) {
        return [pscustomobject]@{ Ok = $false; Texto = ('✖ {0}: o servidor demorou demais para responder.' -f $nome); Detalhe = 'Timeout ao verificar a pasta' }
    }
    if (-not $acesso.Existe) {
        return [pscustomobject]@{
            Ok      = $false
            Texto   = ('✖ {0}: pasta não encontrada ou sem permissão de acesso.' -f $nome)
            Detalhe = 'Directory.Exists = False (caminho inexistente, renomeado ou sem permissão)'
        }
    }

    $textoLetra = ''
    $letra = [string]$Compartilhamento.LetraUnidade
    if ($letra) {
        $rc = Connect-RecursoRede -Remoto $caminho -Letra $letra.ToUpperInvariant() -Persistente
        if ($rc -eq 0) { $textoLetra = (' Unidade {0} mapeada.' -f $letra.ToUpperInvariant()) }
        else { $textoLetra = (' Unidade {0} não mapeada: {1}' -f $letra.ToUpperInvariant(), (Get-MensagemErro $rc)) }
    }

    # O caminho vem da configuração validada e vai entre aspas como UM
    # argumento do explorer.exe — sem passar por cmd.exe.
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $caminho) -ErrorAction Stop
    return [pscustomobject]@{ Ok = $true; Texto = ('✔ {0}: pasta aberta.{1}' -f $nome, $textoLetra); Detalhe = '' }
}

Export-ModuleMember -Function *
