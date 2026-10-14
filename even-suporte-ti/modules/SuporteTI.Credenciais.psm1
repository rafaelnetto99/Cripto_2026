<#
    Arquivo : modules\SuporteTI.Credenciais.psm1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Credenciais no Gerenciador de Credenciais do Windows, SEM cmdkey.exe.

    Por que não usar cmdkey /add ... /pass:SENHA ?
      - a senha vai na linha de comando de outro processo (visível em
        listas de processos, EDR e auditoria de linha de comando 4688);
      - caracteres como % ^ & | < > " ! são interpretados pelo cmd.exe e
        podem corromper a senha ou executar comandos (injeção);
      - o resultado só pode ser conferido por texto traduzido do /list.

    Aqui a senha permanece em SecureString, é copiada para memória não
    gerenciada só durante a chamada à API (CredWrite/LogonUser) e a
    memória é zerada logo em seguida. Nunca vira System.String.
#>
Set-StrictMode -Version 2.0

$script:TipoCredencialDominio = 2   # CRED_TYPE_DOMAIN_PASSWORD (o mesmo do cmdkey /add)

function Get-CredencialWindows {
    <# Informa se existe credencial de domínio para o destino. Nunca lê a senha. #>
    param([Parameter(Mandatory)][string]$Destino)
    $usuario = $null
    $codigo = [EvenSuporte.Nativo]::LerUsuarioCredencial($Destino, $script:TipoCredencialDominio, [ref]$usuario)
    return [pscustomobject]@{
        Existe  = ($codigo -eq 0)
        Usuario = $usuario
        Codigo  = $codigo
    }
}

function Set-CredencialWindows {
    <# Grava (ou substitui) a credencial e confere que ela foi realmente gravada. #>
    param(
        [Parameter(Mandatory)][string]$Destino,
        [Parameter(Mandatory)][string]$Usuario,
        [Parameter(Mandatory)][Security.SecureString]$Senha
    )
    $config = (Get-SuporteContexto).Config
    $persistencia = if ($config.Credenciais.PersistenciaEnterprise) { 3 } else { 2 }  # ENTERPRISE : LOCAL_MACHINE

    # A credencial anterior só é substituída se a nova for gravada com
    # sucesso (a BAT apagava antes e podia deixar o usuário sem nenhuma).
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Senha)
        $codigo = [EvenSuporte.Nativo]::GravarCredencial($Destino, $Usuario, $ptr, $Senha.Length, $script:TipoCredencialDominio, $persistencia)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
    }

    if ($codigo -ne 0) {
        return [pscustomobject]@{ Ok = $false; Codigo = $codigo; Mensagem = (Get-MensagemErro $codigo) }
    }

    $conferencia = Get-CredencialWindows -Destino $Destino
    if (-not $conferencia.Existe -or -not [string]::Equals($conferencia.Usuario, $Usuario, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Ok = $false; Codigo = $conferencia.Codigo; Mensagem = 'A credencial não pôde ser confirmada após a gravação.' }
    }
    return [pscustomobject]@{ Ok = $true; Codigo = 0; Mensagem = 'Credencial salva e conferida.' }
}

function Remove-CredencialWindows {
    param([Parameter(Mandatory)][string]$Destino)
    $codigo = [EvenSuporte.Nativo]::ExcluirCredencial($Destino, $script:TipoCredencialDominio)
    return [pscustomobject]@{ Ok = ($codigo -eq 0 -or $codigo -eq 1168); Codigo = $codigo }
}

function Test-CredencialDominio {
    <#
        Confere usuário/senha no domínio com logon de REDE (não abre sessão).
        Status: Valida | Invalida | Indisponivel | NaoValidada
        Atenção: senha errada conta para bloqueio de conta.
    #>
    param(
        [Parameter(Mandatory)][object]$Usuario,          # saída de ConvertTo-UsuarioDominio
        [Parameter(Mandatory)][Security.SecureString]$Senha
    )
    $config = (Get-SuporteContexto).Config
    if (-not $config.Dominio.ValidarSenhaNoDominio) {
        return [pscustomobject]@{ Status = 'NaoValidada'; Codigo = ''; Texto = '⚠ A senha não foi conferida no domínio (validação desativada na configuração).' }
    }

    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Senha)
        $codigo = [EvenSuporte.Nativo]::ValidarLogonRede($Usuario.Sam, $Usuario.Dominio, $ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
    }

    # 1385 = senha correta, mas tipo de logon não concedido nesta máquina
    if ($codigo -eq 0 -or $codigo -eq 1385) {
        return [pscustomobject]@{ Status = 'Valida'; Codigo = [string]$codigo; Texto = '✔ Usuário e senha conferidos no domínio.' }
    }
    if (@(86, 1326, 1327, 1328, 1329, 1330, 1331, 1793, 1907, 1909) -contains $codigo) {
        return [pscustomobject]@{ Status = 'Invalida'; Codigo = [string]$codigo; Texto = ('✖ {0}' -f (Get-MensagemErro $codigo)) }
    }
    return [pscustomobject]@{
        Status = 'Indisponivel'
        Codigo = [string]$codigo
        Texto  = ('⚠ Não foi possível conferir a senha agora: {0}' -f (Get-MensagemErro $codigo))
    }
}

function Save-CredencialServidores {
    <#
        Salva a mesma credencial para uma lista de servidores e, opcionalmente,
        testa o acesso SMB (IPC$) a cada um. Devolve itens legíveis e contagens.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Servidores,
        [Parameter(Mandatory)][object]$Usuario,
        [Parameter(Mandatory)][Security.SecureString]$Senha,
        [switch]$TestarAcessoSmb
    )
    $config = (Get-SuporteContexto).Config
    $portaSmb = [int]$config.Rede.PortaSmb
    $itens = New-Object System.Collections.Generic.List[string]
    $sucessos = 0; $falhas = 0; $avisos = 0
    $codigo = ''
    $detalhes = New-Object System.Collections.Generic.List[string]

    foreach ($servidor in $Servidores) {
        Send-Progresso -Texto ('Salvando credencial para {0}...' -f $servidor)
        $gravacao = Set-CredencialWindows -Destino $servidor -Usuario $Usuario.Completo -Senha $Senha
        if (-not $gravacao.Ok) {
            $falhas++
            $codigo = [string]$gravacao.Codigo
            $itens.Add(('✖ {0}: credencial NÃO foi salva. {1}' -f $servidor, $gravacao.Mensagem))
            $detalhes.Add(('CredWrite {0} -> {1}' -f $servidor, $gravacao.Codigo))
            continue
        }
        $itens.Add(('✔ {0}: credencial salva.' -f $servidor))
        $detalhes.Add(('CredWrite {0} -> 0' -f $servidor))

        if (-not $TestarAcessoSmb) { $sucessos++; continue }

        # Sessões antigas mantêm o usuário anterior em cache: encerra antes de testar.
        $sessoes = Clear-SessoesServidor -Servidor $servidor
        if ($sessoes.UnidadesComLetra -gt 0) {
            $avisos++
            $itens.Add(('⚠ {0}: há unidade(s) com letra ligadas a este servidor; se o acesso falhar, faça logoff e entre de novo.' -f $servidor))
        }

        Send-Progresso -Texto ('Testando acesso a {0}...' -f $servidor)
        $porta = Test-PortaTcp -Destino $servidor -Porta $portaSmb
        if (-not $porta.Ok) {
            $avisos++
            $sucessos++
            $itens.Add(('⚠ {0}: servidor inacessível agora. A credencial foi salva e será usada quando houver conexão (rede/VPN).' -f $servidor))
            $detalhes.Add(('TCP {0}:{1} -> {2}' -f $servidor, $portaSmb, $porta.Motivo))
            continue
        }

        $rc = Connect-RecursoRede -Remoto ('\\{0}\IPC$' -f $servidor)
        $detalhes.Add(('WNetAddConnection2 \\{0}\IPC$ -> {1}' -f $servidor, $rc))
        if ($rc -eq 0) {
            $sucessos++
            $itens.Add(('✔ {0}: acesso confirmado.' -f $servidor))
        }
        elseif (@(86, 1326, 1909, 1330, 1331, 1907) -contains $rc) {
            $falhas++
            $codigo = [string]$rc
            $itens.Add(('✖ {0}: o servidor recusou a credencial. {1}' -f $servidor, (Get-MensagemErro $rc)))
        }
        else {
            $avisos++
            $sucessos++
            $itens.Add(('⚠ {0}: credencial salva, mas o acesso não foi confirmado. {1}' -f $servidor, (Get-MensagemErro $rc)))
        }
    }

    return [pscustomobject]@{
        Itens    = $itens.ToArray()
        Sucessos = $sucessos
        Falhas   = $falhas
        Avisos   = $avisos
        Codigo   = $codigo
        Detalhes = ($detalhes -join '; ')
    }
}

Export-ModuleMember -Function *
