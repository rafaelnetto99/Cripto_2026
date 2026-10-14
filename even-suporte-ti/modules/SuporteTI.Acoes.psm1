<#
    Arquivo : modules\SuporteTI.Acoes.psm1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Regras de negócio de cada função da Central. A interface chama
    apenas Invoke-AcaoSuporte, que:
      1. confere a permissão do perfil NA HORA da execução;
      2. executa a ação e transforma erros em mensagens amigáveis;
      3. registra o resultado no log (sem senhas);
      4. descarta a senha (SecureString) ao final.
#>
Set-StrictMode -Version 2.0

#region Despachante -----------------------------------------------------------

function Invoke-AcaoSuporte {
    param(
        [Parameter(Mandatory)][string]$Id,
        [hashtable]$Parametros = @{}
    )
    $resultado = $null
    try {
        Assert-PermissaoRecurso -Id $Id
        Write-SuporteLog -Funcao $Id -Resultado Inicio -Mensagem 'Execução iniciada.'
        switch ($Id) {
            'CredencialCubo'     { $resultado = Invoke-AcaoCredencialCubo -Parametros $Parametros }
            'MapearPastas'       { $resultado = Invoke-AcaoMapearPastas -Parametros $Parametros }
            'CredencialAD'       { $resultado = Invoke-AcaoCredencialAD -Parametros $Parametros }
            'LimpezaTemporarios' { $resultado = Invoke-AcaoLimpeza -Parametros $Parametros }
            'Impressoras'        { $resultado = Invoke-AcaoImpressoras -Parametros $Parametros }
            'AbrirPastas'        { $resultado = Invoke-AcaoAbrirPastas -Parametros $Parametros }
            'AbrirAD'            { $resultado = Invoke-AcaoAbrirAD -Parametros $Parametros }
            'InstalarRSAT'       { $resultado = Invoke-AcaoInstalarRsat }
            'Diagnostico'        { $resultado = Invoke-AcaoDiagnostico }
            'VerLogs'            { $resultado = Invoke-AcaoVerLogs }
            default              { throw ('Ação desconhecida: {0}' -f $Id) }
        }
        if (-not $resultado) { throw 'A ação não retornou resultado.' }
    }
    catch {
        $resultado = ConvertTo-ResultadoErro -Registro $_
    }
    finally {
        if ($Parametros -and $Parametros.ContainsKey('Senha') -and $Parametros['Senha'] -is [Security.SecureString]) {
            $Parametros['Senha'].Dispose()
            $Parametros.Remove('Senha')
        }
    }

    $mensagemLog = (@($resultado.Mensagem, $resultado.Detalhes) | Where-Object { $_ }) -join ' | '
    Write-SuporteLog -Funcao $Id -Resultado $resultado.Status -Mensagem $mensagemLog -Elevacao $resultado.Elevacao -CodigoErro $resultado.CodigoErro
    return $resultado
}

function ConvertTo-ResultadoErro {
    <# Erro técnico -> mensagem amigável para a tela + detalhe só para log/cópia. #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$Registro)
    $mensagem = $Registro.Exception.Message
    if ($mensagem -like 'ACESSO_NEGADO:*') {
        return New-ResultadoAcao -Status Negado -Mensagem 'Você não tem permissão para usar esta função.' `
            -Recomendacao 'Se precisar dela, abra um chamado para a equipe de TI.' -Detalhes $mensagem
    }
    if ($mensagem -like 'CONFIG_PENDENTE:*') {
        return New-ResultadoAcao -Status Falha -Mensagem 'Esta função ainda não foi configurada pela equipe de TI.' `
            -Recomendacao 'Avise a TI. (Configuração pendente: TODO_VALIDAR)' -Detalhes $mensagem
    }
    $detalhe = '{0} | {1} | {2}' -f $Registro.Exception.GetType().FullName, (Get-MensagemInterna $Registro.Exception), $Registro.InvocationInfo.PositionMessage
    return New-ResultadoAcao -Status Falha -Mensagem 'Ocorreu um erro inesperado e a operação não foi concluída.' `
        -Recomendacao 'Tente novamente. Se persistir, clique em "Copiar detalhes técnicos" e envie para a TI.' `
        -Detalhes $detalhe -CodigoErro (Get-CodigoErroExcecao $Registro.Exception)
}

function Get-ConfigAtual { return (Get-SuporteContexto).Config }

#endregion

#region Elevação pontual -------------------------------------------------------

function Invoke-AcaoElevada {
    <#
        Executa UMA tarefa administrativa em um processo separado e elevado
        (UAC). A aplicação principal continua sem privilégios.
        Só aceita ações e Ids da lista fixa; nada digitado pelo usuário vai
        para a linha de comando.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('LimparTempWindows', 'InstalarImpressoras', 'InstalarRSAT')][string]$Acao,
        [string[]]$Ids = @()
    )
    $ctx = Get-SuporteContexto
    foreach ($i in $Ids) { if ($i -notmatch '^[A-Za-z0-9_]{1,40}$') { throw ('Id inválido: {0}' -f $i) } }

    if ($ctx.Config.Aplicacao.ExigirPastaProtegidaParaElevacao -and -not (Test-PastaProtegida -Pasta $ctx.AppRoot -Config $ctx.Config)) {
        return New-ResultadoAcao -Status Falha -Elevacao 'Bloqueada' `
            -Mensagem 'Esta tarefa exige administrador e a ferramenta não está instalada numa pasta protegida.' `
            -Recomendacao 'Instale a ferramenta em C:\Program Files\EVEN\SuporteTI (ou ajuste PastasConfiaveis em homologação).' `
            -Detalhes ('AppRoot={0}' -f $ctx.AppRoot)
    }

    $pastaRun = Join-Path $env:LOCALAPPDATA 'EVEN\SuporteTI\run'
    if (-not (Test-Path -LiteralPath $pastaRun -PathType Container)) { [void](New-Item -ItemType Directory -Path $pastaRun -Force -ErrorAction Stop) }
    $arquivo = Join-Path $pastaRun ('resultado_{0}.json' -f [guid]::NewGuid().ToString())
    $scriptElevado = Join-Path $ctx.AppRoot 'SuporteTI.Elevado.ps1'
    if (-not (Test-Path -LiteralPath $scriptElevado -PathType Leaf)) { throw ('Script elevado não encontrado: {0}' -f $scriptElevado) }

    $argumentos = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $scriptElevado), '-Acao', $Acao, '-ArquivoResultado', ('"{0}"' -f $arquivo))
    if ($Ids.Count -gt 0) { $argumentos += @('-Ids', ($Ids -join ',')) }

    Send-Progresso -Texto 'Aguardando autorização de administrador (janela do Windows/UAC)...'
    try {
        $processo = Start-Process -FilePath (Get-CaminhoPowerShell) -ArgumentList $argumentos -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        $codigo = Get-CodigoErroExcecao $_.Exception
        if ($codigo -eq '1223' -or (Get-MensagemInterna $_.Exception) -match 'cancel') {
            return New-ResultadoAcao -Status Cancelado -Elevacao 'Negada' -CodigoErro '1223' `
                -Mensagem 'A permissão de administrador não foi concedida.' `
                -Recomendacao 'Esta parte precisa de um técnico de TI com acesso de administrador.'
        }
        return New-ResultadoAcao -Status Falha -Elevacao 'Falhou' -CodigoErro $codigo `
            -Mensagem 'Não foi possível iniciar a tarefa administrativa.' -Detalhes (Get-MensagemInterna $_.Exception)
    }

    if (-not (Test-Path -LiteralPath $arquivo -PathType Leaf)) {
        return New-ResultadoAcao -Status Falha -Elevacao 'Concedida' -CodigoErro ([string]$processo.ExitCode) `
            -Mensagem 'A tarefa administrativa terminou sem informar o resultado.' `
            -Recomendacao 'Verifique a política de execução de scripts e a assinatura dos arquivos.' `
            -Detalhes ('Código de saída do processo elevado: {0}' -f $processo.ExitCode)
    }
    try {
        $json = [IO.File]::ReadAllText($arquivo, [Text.Encoding]::UTF8)
        $r = ConvertFrom-Json -InputObject $json
    }
    finally {
        Remove-Item -LiteralPath $arquivo -Force -ErrorAction SilentlyContinue
    }
    $itens = @()
    if ($r.PSObject.Properties['Itens'] -and $r.Itens) { $itens = @($r.Itens) }
    return New-ResultadoAcao -Status $r.Status -Mensagem $r.Mensagem -Recomendacao $r.Recomendacao -Itens $itens `
        -Detalhes $r.Detalhes -CodigoErro $r.CodigoErro -Elevacao 'Concedida' -Dados $r.Dados
}

#endregion

#region Credenciais (Cubo, servidores de arquivos, AD) ------------------------

function Invoke-FluxoCredencial {
    <# Normaliza usuário, confere senha no domínio e salva para os servidores. #>
    param(
        [Parameter(Mandatory)][string[]]$Servidores,
        [Parameter(Mandatory)][hashtable]$Parametros,
        [switch]$TestarAcessoSmb
    )
    $config = Get-ConfigAtual
    $usuario = ConvertTo-UsuarioDominio -Entrada ([string]$Parametros['Usuario']) -Config $config
    if (-not $usuario.Valido) {
        return @{ Erro = (New-ResultadoAcao -Status Falha -Mensagem $usuario.Mensagem -Recomendacao 'Digite apenas o seu usuário de rede, por exemplo: joao.silva') }
    }
    $senha = $Parametros['Senha']
    if (-not ($senha -is [Security.SecureString]) -or $senha.Length -eq 0) {
        return @{ Erro = (New-ResultadoAcao -Status Falha -Mensagem 'Informe a senha.') }
    }

    Send-Progresso -Texto 'Conferindo usuário e senha no domínio...' -Percentual 15
    $validacao = Test-CredencialDominio -Usuario $usuario -Senha $senha
    if ($validacao.Status -eq 'Invalida') {
        return @{ Erro = (New-ResultadoAcao -Status Falha -Mensagem ($validacao.Texto.TrimStart('✖', ' ')) -CodigoErro $validacao.Codigo `
                -Recomendacao 'Confira usuário e senha (Caps Lock?). Após várias tentativas a conta pode ser bloqueada.' `
                -Detalhes ('LogonUser({0}) -> {1}' -f $usuario.Completo, $validacao.Codigo)) }
    }
    if ($validacao.Status -eq 'Indisponivel' -and -not $config.Dominio.PermitirSalvarSemValidar) {
        return @{ Erro = (New-ResultadoAcao -Status Falha -Mensagem 'Não foi possível conferir a senha porque o domínio não respondeu.' `
                -Recomendacao 'Conecte-se à rede da empresa ou à VPN e tente novamente.' -CodigoErro $validacao.Codigo) }
    }

    Send-Progresso -Texto 'Salvando credencial...' -Percentual 45
    $gravacao = Save-CredencialServidores -Servidores $Servidores -Usuario $usuario -Senha $senha -TestarAcessoSmb:$TestarAcessoSmb

    $itens = @($validacao.Texto) + @($gravacao.Itens)
    $avisos = $gravacao.Avisos
    if ($validacao.Status -ne 'Valida') { $avisos++ }
    return @{
        Erro     = $null
        Usuario  = $usuario
        Itens    = $itens
        Sucessos = $gravacao.Sucessos
        Falhas   = $gravacao.Falhas
        Avisos   = $avisos
        Codigo   = $(if ($gravacao.Codigo) { $gravacao.Codigo } else { $validacao.Codigo })
        Detalhes = ('Usuário={0}; Validação={1}({2}); {3}' -f $usuario.Completo, $validacao.Status, $validacao.Codigo, $gravacao.Detalhes)
    }
}

function Invoke-AcaoCredencialCubo {
    param([hashtable]$Parametros)
    $config = Get-ConfigAtual
    $servidor = [string](Assert-ValorConfigurado -Valor $config.Cubo.Servidor -Chave 'Cubo.Servidor')

    $fluxo = Invoke-FluxoCredencial -Servidores @($servidor) -Parametros $Parametros
    if ($fluxo.Erro) { return $fluxo.Erro }

    $itens = @($fluxo.Itens)
    $avisos = $fluxo.Avisos
    $portaTeste = 0
    [void][int]::TryParse([string]$config.Cubo.PortaTeste, [ref]$portaTeste)
    if ($portaTeste -gt 0 -and $fluxo.Falhas -eq 0) {
        Send-Progresso -Texto 'Testando conexão com o Cubo...' -Percentual 80
        $t = Test-PortaTcp -Destino $servidor -Porta $portaTeste
        if ($t.Ok) { $itens += '✔ Servidor do Cubo respondeu.' }
        else { $avisos++; $itens += '⚠ O servidor do Cubo não respondeu agora (rede/VPN?). A credencial foi salva.' }
    }

    $status = Get-StatusFinal -Sucessos $fluxo.Sucessos -Falhas $fluxo.Falhas -Avisos $avisos
    $mensagem = switch ($status) {
        'Sucesso' { 'Credencial do Cubo atualizada.' }
        'Aviso'   { 'Credencial do Cubo salva, com observações.' }
        default   { 'A credencial do Cubo não foi atualizada.' }
    }
    $recomendacao = if ($status -eq 'Sucesso') { 'Feche e abra novamente o Excel/relatório que usa o Cubo.' } elseif ($status -eq 'Aviso') { 'Se o Cubo não abrir, conecte-se à rede/VPN e repita.' } else { 'Tente novamente. Se persistir, copie os detalhes e envie à TI.' }
    return New-ResultadoAcao -Status $status -Mensagem $mensagem -Recomendacao $recomendacao -Itens $itens -Detalhes $fluxo.Detalhes -CodigoErro $fluxo.Codigo
}

function Invoke-AcaoCredencialAD {
    param([hashtable]$Parametros)
    $config = Get-ConfigAtual
    $servidor = [string](Assert-ValorConfigurado -Valor $config.ServidorAD.Servidor -Chave 'ServidorAD.Servidor')
    $fluxo = Invoke-FluxoCredencial -Servidores @($servidor) -Parametros $Parametros -TestarAcessoSmb
    if ($fluxo.Erro) { return $fluxo.Erro }
    $status = Get-StatusFinal -Sucessos $fluxo.Sucessos -Falhas $fluxo.Falhas -Avisos $fluxo.Avisos
    $mensagem = if ($status -eq 'Falha') { 'A credencial administrativa do AD não foi configurada.' } else { 'Credencial administrativa do AD configurada.' }
    return New-ResultadoAcao -Status $status -Mensagem $mensagem -Itens $fluxo.Itens -Detalhes $fluxo.Detalhes -CodigoErro $fluxo.Codigo `
        -Recomendacao $(if ($status -eq 'Falha') { 'Confira o usuário de suporte e a senha.' } else { 'Use "Abrir Active Directory".' })
}

function Invoke-AcaoMapearPastas {
    param([hashtable]$Parametros)
    $config = Get-ConfigAtual
    $servidores = @(@($config.ServidoresArquivos) | Where-Object { -not (Test-ValorPendente $_) })
    if ($servidores.Count -eq 0) { [void](Assert-ValorConfigurado -Valor $null -Chave 'ServidoresArquivos') }

    $fluxo = Invoke-FluxoCredencial -Servidores $servidores -Parametros $Parametros -TestarAcessoSmb
    if ($fluxo.Erro) { return $fluxo.Erro }

    $itens = @($fluxo.Itens)
    $sucessos = $fluxo.Sucessos; $falhas = $fluxo.Falhas; $avisos = $fluxo.Avisos
    $detalhes = @($fluxo.Detalhes)

    if ($fluxo.Falhas -eq 0) {
        $pastas = @(Get-CompartilhamentosPermitidos | Where-Object { $_.AbrirAoMapear })
        $n = 0
        foreach ($c in $pastas) {
            $n++
            Send-Progresso -Texto ('Abrindo pasta {0} de {1}...' -f $n, $pastas.Count) -Percentual (60 + [int](35 * $n / [Math]::Max($pastas.Count, 1)))
            try {
                $r = Open-Compartilhamento -Compartilhamento $c
                $itens += $r.Texto
                if ($r.Ok) { $sucessos++ } else { $falhas++; $detalhes += $r.Detalhe }
            }
            catch {
                $falhas++
                $itens += ('✖ {0}: {1}' -f $c.Nome, $(if ($_.Exception.Message -like 'CONFIG_PENDENTE:*') { 'pasta ainda não configurada pela TI.' } else { 'não foi possível abrir.' }))
                $detalhes += (Get-MensagemInterna $_.Exception)
            }
        }
    }
    else {
        $itens += '⚠ As pastas não foram abertas porque a credencial não foi aceita.'
    }

    $status = Get-StatusFinal -Sucessos $sucessos -Falhas $falhas -Avisos $avisos
    $mensagem = switch ($status) {
        'Sucesso' { 'Credenciais atualizadas e pastas abertas.' }
        'Aviso'   { 'Concluído, com observações.' }
        'Parcial' { 'Concluído parcialmente: veja os itens abaixo.' }
        default   { 'Não foi possível mapear as pastas.' }
    }
    return New-ResultadoAcao -Status $status -Mensagem $mensagem -Itens $itens -Detalhes ($detalhes -join ' | ') -CodigoErro $fluxo.Codigo `
        -Recomendacao $(if ($status -eq 'Sucesso') { '' } else { 'Verifique a rede/VPN. Se uma pasta não abrir, envie os detalhes à TI.' })
}

function Invoke-AcaoAbrirPastas {
    param([hashtable]$Parametros)
    $selecionados = @($Parametros['Ids'])
    $permitidos = Get-CompartilhamentosPermitidos
    $alvos = @($permitidos | Where-Object { $selecionados -contains $_.Id })
    if ($alvos.Count -eq 0) { return New-ResultadoAcao -Status Falha -Mensagem 'Selecione ao menos uma pasta.' }

    $itens = @(); $detalhes = @(); $ok = 0; $falhas = 0
    foreach ($c in $alvos) {
        try {
            $r = Open-Compartilhamento -Compartilhamento $c
            $itens += $r.Texto
            if ($r.Ok) { $ok++ } else { $falhas++; $detalhes += $r.Detalhe }
        }
        catch {
            $falhas++
            $itens += ('✖ {0}: não foi possível abrir.' -f $c.Nome)
            $detalhes += (Get-MensagemInterna $_.Exception)
        }
    }
    $status = Get-StatusFinal -Sucessos $ok -Falhas $falhas
    $mensagem = if ($status -eq 'Sucesso') { 'Pastas abertas.' } elseif ($status -eq 'Parcial') { 'Algumas pastas não abriram.' } else { 'Nenhuma pasta pôde ser aberta.' }
    return New-ResultadoAcao -Status $status -Mensagem $mensagem -Itens $itens -Detalhes ($detalhes -join ' | ') `
        -Recomendacao $(if ($falhas) { 'Use "Mapear pastas" para atualizar sua credencial e confira a rede/VPN.' } else { '' })
}

#endregion

#region Limpeza ----------------------------------------------------------------

function Invoke-AcaoLimpeza {
    param([hashtable]$Parametros)
    $config = Get-ConfigAtual
    $selecao = @($Parametros['Ids'])
    if ($selecao.Count -eq 0) { return New-ResultadoAcao -Status Falha -Mensagem 'Selecione ao menos um item para limpar.' }

    $itens = @(); $detalhes = @()
    $executados = 0; $naoExecutados = 0
    $elevacao = 'NaoNecessaria'

    if ($selecao -contains 'TempUsuario') {
        Send-Progresso -Texto 'Limpando temporários do usuário...' -Percentual 10
        try {
            $e = Clear-PastaTemporaria -Tipo Usuario
            $itens += (Format-ResumoLimpeza $e)
            if ($e.Executado) { $executados++ } else { $naoExecutados++ }
        }
        catch { $naoExecutados++; $itens += '✖ Temporários do usuário: não executado.'; $detalhes += (Get-MensagemInterna $_.Exception) }
    }

    if ($selecao -contains 'TempWindows') {
        Send-Progresso -Texto 'Limpando temporários do Windows...' -Percentual 40
        if (-not $config.Limpeza.PermitirTempWindows) {
            $naoExecutados++; $itens += '⚠ Temporários do Windows: desativado na configuração.'
        }
        elseif (Test-Administrador) {
            $elevacao = 'JaElevado'
            try {
                $e = Clear-PastaTemporaria -Tipo Windows
                $itens += (Format-ResumoLimpeza $e)
                if ($e.Executado) { $executados++ } else { $naoExecutados++ }
            }
            catch { $naoExecutados++; $itens += '✖ Temporários do Windows: não executado.'; $detalhes += (Get-MensagemInterna $_.Exception) }
        }
        else {
            $r = Invoke-AcaoElevada -Acao LimparTempWindows
            $elevacao = $r.Elevacao
            if ($r.Status -eq 'Sucesso' -and $r.Dados) {
                $itens += (Format-ResumoLimpeza $r.Dados)
                if ($r.Dados.Executado) { $executados++ } else { $naoExecutados++ }
            }
            else {
                $naoExecutados++
                $itens += ('⚠ Temporários do Windows: não executado por falta de permissão de administrador. {0}' -f $r.Mensagem)
                if ($r.Detalhes) { $detalhes += $r.Detalhes }
            }
        }
    }

    if ($selecao -contains 'Lixeira') {
        Send-Progresso -Texto 'Esvaziando a Lixeira...' -Percentual 80
        if (-not $config.Limpeza.PermitirLixeira) {
            $naoExecutados++; $itens += '⚠ Lixeira: desativado na configuração.'
        }
        else {
            try {
                $l = Clear-LixeiraUsuario
                if ($l.Executado) {
                    $executados++
                    if ($l.Observacao) { $itens += ('✔ Lixeira: {0}' -f $l.Observacao) }
                    elseif ($l.Removidos -ge 0) { $itens += ('✔ Lixeira: {0} item(ns) removido(s) ({1}).' -f $l.Removidos, (Format-Tamanho ([long]$l.Bytes))) }
                    else { $itens += '✔ Lixeira esvaziada.' }
                }
                else {
                    $naoExecutados++
                    $itens += ('✖ Lixeira: {0}' -f $l.Observacao)
                    $detalhes += ('SHEmptyRecycleBin -> {0}' -f $l.Codigo)
                }
            }
            catch { $naoExecutados++; $itens += '✖ Lixeira: não executado.'; $detalhes += (Get-MensagemInterna $_.Exception) }
        }
    }

    $itens += 'ℹ Arquivos em uso por programas abertos são ignorados — isso é normal.'
    $status = Get-StatusFinal -Sucessos $executados -Falhas $naoExecutados
    $mensagem = switch ($status) {
        'Sucesso' { 'Limpeza concluída.' }
        'Parcial' { 'Limpeza concluída parcialmente.' }
        default   { 'A limpeza não foi executada.' }
    }
    return New-ResultadoAcao -Status $status -Mensagem $mensagem -Itens $itens -Detalhes ($detalhes -join ' | ') -Elevacao $elevacao `
        -Recomendacao $(if ($status -ne 'Sucesso') { 'Para limpar os temporários do Windows, peça a um técnico de TI.' } else { '' })
}

#endregion

#region Impressoras ------------------------------------------------------------

function Invoke-AcaoImpressoras {
    param([hashtable]$Parametros)
    $habilitadas = Get-ImpressorasHabilitadas
    $selecionadas = @($Parametros['Ids'] | Where-Object { $_ -ne '__TODAS__' })
    $alvos = @($habilitadas | Where-Object { $selecionadas -contains $_.Id })
    if ($alvos.Count -eq 0) { return New-ResultadoAcao -Status Falha -Mensagem 'Selecione ao menos uma impressora.' }

    # 1) Pré-checagem sem privilégio: evita pedir UAC à toa.
    $resultados = New-Object System.Collections.Generic.List[object]
    $pendentes = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($imp in $alvos) {
        $n++
        Send-Progresso -Texto ('Verificando {0}...' -f $imp.Nome) -Percentual ([int](30 * $n / $alvos.Count))
        $estado = Get-EstadoImpressora -Impressora $imp
        if ($estado.Estado -eq 'Pendente') { $pendentes.Add([string]$imp.Id) } else { $resultados.Add($estado) }
    }

    # 2) Instalação (elevada somente se necessário).
    $elevacao = 'NaoNecessaria'
    $mensagemElevacao = ''
    if ($pendentes.Count -gt 0) {
        if (Test-Administrador) {
            $elevacao = 'JaElevado'
            foreach ($r in (Install-Impressoras -Ids $pendentes.ToArray())) { $resultados.Add($r) }
        }
        else {
            $r = Invoke-AcaoElevada -Acao InstalarImpressoras -Ids $pendentes.ToArray()
            $elevacao = $r.Elevacao
            if ($r.Status -eq 'Sucesso' -and $r.Dados) {
                foreach ($x in @($r.Dados)) { $resultados.Add($x) }
            }
            else {
                $mensagemElevacao = $r.Mensagem
                foreach ($id in $pendentes) {
                    $imp = Get-ImpressoraConfig -Id $id
                    $resultados.Add((New-ResultadoImpressora -Impressora $imp -Estado 'Falhou' `
                        -Texto ('✖ {0}: não instalada — exige permissão de administrador.' -f $imp.Nome) -Detalhe $r.Detalhes))
                }
            }
        }
    }

    # 3) Consolidação: cada impressora tem seu próprio resultado.
    $ok = @($resultados | Where-Object { $_.Estado -eq 'Instalada' -or $_.Estado -eq 'JaExistia' }).Count
    $falhas = @($resultados | Where-Object { $_.Estado -eq 'Falhou' -or $_.Estado -eq 'Ignorada' })
    $itens = @($resultados | ForEach-Object { $_.Texto })
    $detalhes = @($resultados | Where-Object { $_.Detalhe } | ForEach-Object { '{0}: {1}' -f $_.Nome, $_.Detalhe })

    $status = Get-StatusFinal -Sucessos $ok -Falhas $falhas.Count
    $mensagem = switch ($status) {
        'Sucesso' { 'Impressoras prontas para uso.' }
        'Parcial' { ('{0} impressora(s) pronta(s) e {1} com problema.' -f $ok, $falhas.Count) }
        default   { 'Nenhuma impressora pôde ser instalada.' }
    }
    if ($mensagemElevacao) { $mensagem += (' ' + $mensagemElevacao) }

    # Alternativa da BAT, agora UMA vez ao final: abre o painel de
    # impressoras e copia o endereço da primeira que falhou.
    $posAcao = $null
    $recomendacao = ''
    $falhaComIp = @($falhas | Where-Object { $_.Estado -eq 'Falhou' -and $_.IP }) | Select-Object -First 1
    if ($falhaComIp) {
        $posAcao = @{ Tipo = 'PainelImpressoras'; Valor = [string]$falhaComIp.IP }
        $recomendacao = ('O painel de impressoras será aberto para instalação manual. O endereço de "{0}" foi copiado (Ctrl+V). Se não conseguir, chame a TI.' -f $falhaComIp.Nome)
    }
    elseif ($falhas.Count -gt 0) {
        $recomendacao = 'Verifique se está na rede da empresa e se a impressora está ligada; depois tente de novo.'
    }

    return New-ResultadoAcao -Status $status -Mensagem $mensagem -Itens $itens -Detalhes ($detalhes -join ' | ') `
        -Elevacao $elevacao -Recomendacao $recomendacao -PosAcao $posAcao
}

#endregion

#region Active Directory -------------------------------------------------------

function Invoke-AcaoAbrirAD {
    param([hashtable]$Parametros)
    $config = Get-ConfigAtual
    $servidor = [string](Assert-ValorConfigurado -Valor $config.ServidorAD.Servidor -Chave 'ServidorAD.Servidor')
    $itens = @()

    # 1) RSAT antes de qualquer conexão (a BAT autenticava antes de checar).
    Send-Progresso -Texto 'Verificando RSAT...' -Percentual 10
    $rsat = Test-RsatAD
    if (-not $rsat.Instalado) {
        return New-ResultadoAcao -Status Falha -Mensagem 'O console do Active Directory (RSAT) não está instalado neste computador.' `
            -Recomendacao 'Um administrador pode usar o botão "Instalar RSAT" nesta tela, ou instale "RSAT: Active Directory Domain Services" em Configurações > Recursos opcionais.' `
            -Detalhes $rsat.Detalhe
    }
    $itens += '✔ Console do Active Directory encontrado.'

    # 2) Conectividade com timeout.
    Send-Progresso -Texto 'Testando conexão com o servidor do AD...' -Percentual 30
    $ldap = Test-PortaTcp -Destino $servidor -Porta ([int]$config.ServidorAD.PortaLdap)
    if (-not $ldap.Ok) {
        return New-ResultadoAcao -Status Falha -Mensagem 'O servidor do Active Directory não respondeu.' `
            -Recomendacao 'Verifique a rede ou a VPN.' -Itens $itens -Detalhes ('LDAP {0}:{1} -> {2}' -f $servidor, $config.ServidorAD.PortaLdap, $ldap.Motivo)
    }
    $itens += '✔ Servidor do AD respondeu.'

    if ([string]$config.ServidorAD.ModoAbertura -eq 'OutroUsuario') {
        $usuario = ConvertTo-UsuarioDominio -Entrada ([string]$Parametros['Usuario']) -Config $config
        if (-not $usuario.Valido) { return New-ResultadoAcao -Status Falha -Mensagem $usuario.Mensagem }
        $senha = $Parametros['Senha']
        if (-not ($senha -is [Security.SecureString]) -or $senha.Length -eq 0) { return New-ResultadoAcao -Status Falha -Mensagem 'Informe a senha.' }

        Send-Progresso -Texto 'Conferindo credencial...' -Percentual 50
        $validacao = Test-CredencialDominio -Usuario $usuario -Senha $senha
        if ($validacao.Status -eq 'Invalida') {
            return New-ResultadoAcao -Status Falha -Mensagem ($validacao.Texto.TrimStart('✖', ' ')) -CodigoErro $validacao.Codigo -Itens $itens
        }
        $credencial = New-Object System.Management.Automation.PSCredential($usuario.Completo, $senha)
        Send-Progresso -Texto 'Abrindo o console como o usuário informado...' -Percentual 75
        $abertura = Open-ConsoleAD -Servidor $servidor -Credencial $credencial
    }
    else {
        # Modo herdado da BAT: credencial salva + sessão IPC$ com o servidor.
        Send-Progresso -Texto 'Verificando credencial salva...' -Percentual 45
        $cred = Get-CredencialWindows -Destino $servidor
        if (-not $cred.Existe) {
            return New-ResultadoAcao -Status Falha -Mensagem 'Credencial do AD não encontrada.' -Itens $itens `
                -Recomendacao 'Configure primeiro em "Configurar credencial administrativa do AD".' -CodigoErro ([string]$cred.Codigo)
        }
        $itens += '✔ Credencial salva encontrada.'

        Send-Progresso -Texto 'Renovando sessão com o servidor...' -Percentual 60
        [void](Clear-SessoesServidor -Servidor $servidor)
        $rc = Connect-RecursoRede -Remoto ('\\{0}\IPC$' -f $servidor)
        if ($rc -ne 0) {
            return New-ResultadoAcao -Status Falha -Mensagem ('Não foi possível autenticar no servidor do AD. {0}' -f (Get-MensagemErro $rc)) `
                -Recomendacao 'Atualize a credencial em "Configurar credencial administrativa do AD".' -Itens $itens `
                -CodigoErro ([string]$rc) -Detalhes ('WNetAddConnection2 \\{0}\IPC$ -> {1}' -f $servidor, $rc)
        }
        $itens += '✔ Autenticado no servidor.'
        Send-Progresso -Texto 'Abrindo o console...' -Percentual 80
        $abertura = Open-ConsoleAD -Servidor $servidor
    }

    if (-not $abertura.Ok) {
        return New-ResultadoAcao -Status Falha -Mensagem 'O console do Active Directory não abriu corretamente.' -Itens $itens -Detalhes $abertura.Detalhe
    }
    $itens += '✔ Console aberto.'
    return New-ResultadoAcao -Status Sucesso -Mensagem 'Active Directory aberto.' -Itens $itens -Detalhes $abertura.Detalhe
}

function Invoke-AcaoInstalarRsat {
    if (Test-Administrador) {
        $r = Install-RsatAD
        $r.Elevacao = 'JaElevado'
        return $r
    }
    return Invoke-AcaoElevada -Acao InstalarRSAT
}

#endregion

#region Diagnóstico e logs (TI) -----------------------------------------------

function Invoke-AcaoDiagnostico {
    $ctx = Get-SuporteContexto
    $config = $ctx.Config
    $linhas = New-Object System.Collections.Generic.List[string]
    $problemas = 0

    $linhas.Add('=== Ambiente ===')
    $linhas.Add(('Ferramenta ............: {0} {1}' -f $config.Aplicacao.Nome, $config.Aplicacao.Versao))
    $linhas.Add(('PowerShell ............: {0} ({1} bits)' -f $PSVersionTable.PSVersion, $(if ([Environment]::Is64BitProcess) { 64 } else { 32 })))
    try {
        $so = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $linhas.Add(('Windows ...............: {0} (build {1})' -f $so.Caption, $so.BuildNumber))
        $linhas.Add(('No domínio ............: {0} ({1})' -f $(if ($cs.PartOfDomain) { 'Sim' } else { 'Não' }), $cs.Domain))
    }
    catch { $linhas.Add('Windows ...............: não foi possível consultar (CIM).') }
    $linhas.Add(('Usuário / perfil ......: {0} / {1}' -f $ctx.Usuario, $ctx.Perfil))
    $linhas.Add(('Motivo do perfil ......: {0}' -f $ctx.MotivoPerfil))
    $linhas.Add(('Processo elevado ......: {0}' -f $(if (Test-Administrador) { 'Sim' } else { 'Não' })))
    $linhas.Add(('Pasta protegida .......: {0} ({1})' -f $(if (Test-PastaProtegida -Pasta $ctx.AppRoot -Config $config) { 'Sim' } else { 'NÃO' }), $ctx.AppRoot))
    $linhas.Add(('Pasta de logs .........: {0}' -f $ctx.DiretorioLog))
    $spooler = Test-SpoolerAtivo
    if (-not $spooler) { $problemas++ }
    $linhas.Add(('Spooler de impressão ..: {0}' -f $(if ($spooler) { 'Em execução' } else { 'PARADO' })))
    $rsat = Test-RsatAD
    $linhas.Add(('RSAT (dsa.msc) ........: {0}' -f $(if ($rsat.Instalado) { 'Instalado' } else { 'Não instalado' })))

    Send-Progresso -Texto 'Verificando credenciais salvas...' -Percentual 20
    $linhas.Add('')
    $linhas.Add('=== Credenciais salvas (apenas existência; conteúdo nunca é lido) ===')
    $destinos = @()
    if (-not (Test-ValorPendente $config.Cubo.Servidor)) { $destinos += [string]$config.Cubo.Servidor }
    if (-not (Test-ValorPendente $config.ServidorAD.Servidor)) { $destinos += [string]$config.ServidorAD.Servidor }
    $destinos += @(@($config.ServidoresArquivos) | Where-Object { -not (Test-ValorPendente $_) })
    foreach ($d in ($destinos | Select-Object -Unique)) {
        $c = Get-CredencialWindows -Destino $d
        $linhas.Add(('{0,-22}: {1}' -f $d, $(if ($c.Existe) { 'existe' } else { 'não existe' })))
    }

    Send-Progresso -Texto 'Testando conectividade...' -Percentual 40
    $linhas.Add('')
    $linhas.Add('=== Conectividade (timeout por teste: {0} ms) ===' -f $config.Rede.TimeoutMs)
    $testes = New-Object System.Collections.Generic.List[object]
    if (-not (Test-ValorPendente $config.ServidorAD.Servidor)) {
        $testes.Add(@{ Rotulo = 'AD (LDAP)'; Destino = [string]$config.ServidorAD.Servidor; Porta = [int]$config.ServidorAD.PortaLdap })
        $testes.Add(@{ Rotulo = 'AD (SMB)'; Destino = [string]$config.ServidorAD.Servidor; Porta = [int]$config.Rede.PortaSmb })
    }
    if (-not (Test-ValorPendente $config.Cubo.Servidor) -and [int]$config.Cubo.PortaTeste -gt 0) {
        $testes.Add(@{ Rotulo = 'Cubo'; Destino = [string]$config.Cubo.Servidor; Porta = [int]$config.Cubo.PortaTeste })
    }
    foreach ($s in @($config.ServidoresArquivos)) {
        if (-not (Test-ValorPendente $s)) { $testes.Add(@{ Rotulo = 'Arquivos'; Destino = [string]$s; Porta = [int]$config.Rede.PortaSmb }) }
    }
    foreach ($imp in (Get-ImpressorasHabilitadas)) {
        if (-not (Test-ValorPendente $imp.IP)) { $testes.Add(@{ Rotulo = ('Impressora {0}' -f $imp.Nome); Destino = [string]$imp.IP; Porta = [int]$imp.Porta }) }
    }
    $n = 0
    foreach ($t in $testes) {
        $n++
        Send-Progresso -Texto ('Testando {0} ({1}/{2})...' -f $t.Rotulo, $n, $testes.Count) -Percentual (40 + [int](50 * $n / [Math]::Max($testes.Count, 1)))
        $r = Test-PortaTcp -Destino $t.Destino -Porta $t.Porta
        if (-not $r.Ok) { $problemas++ }
        $linhas.Add(('{0,-28} {1}:{2,-5} {3}' -f $t.Rotulo, $t.Destino, $t.Porta, $(if ($r.Ok) { ('OK ({0} ms)' -f $r.Ms) } else { ('FALHA - {0}' -f $r.Motivo) })))
    }

    $linhas.Add('')
    $pendentes = @(Get-ValoresPendentes -No $config)
    $linhas.Add(('=== Configuração: {0} valor(es) TODO_VALIDAR ===' -f $pendentes.Count))
    foreach ($p in $pendentes) { $linhas.Add((' - {0}' -f $p)) }
    if (-not $config.Aplicacao.ValoresConfirmadosPelaTI) { $linhas.Add(' - Aplicacao.ValoresConfirmadosPelaTI = $false (valores herdados da BAT não confirmados)') }

    $status = if ($problemas -gt 0) { 'Aviso' } else { 'Sucesso' }
    $mensagem = if ($problemas -gt 0) { ('Diagnóstico concluído com {0} ponto(s) de atenção.' -f $problemas) } else { 'Diagnóstico concluído sem problemas de conectividade.' }
    return New-ResultadoAcao -Status $status -Mensagem $mensagem -Saida ($linhas -join [Environment]::NewLine) `
        -Detalhes ('Problemas={0}; Pendências de configuração={1}' -f $problemas, $pendentes.Count)
}

function Invoke-AcaoVerLogs {
    $ctx = Get-SuporteContexto
    if (-not $ctx.DiretorioLog) { return New-ResultadoAcao -Status Falha -Mensagem 'A pasta de logs não está disponível.' }
    $arquivo = Get-ChildItem -LiteralPath $ctx.DiretorioLog -Filter 'SuporteTI_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    if (-not $arquivo) { return New-ResultadoAcao -Status Aviso -Mensagem 'Ainda não há registros de log.' }

    $max = 300
    [void][int]::TryParse([string]$ctx.Config.Logs.LinhasVisualizacao, [ref]$max)
    $linhas = @(Get-Content -LiteralPath $arquivo.FullName -Tail $max -Encoding UTF8 -ErrorAction Stop)
    [array]::Reverse($linhas)
    $saida = New-Object System.Collections.Generic.List[string]
    $saida.Add(('Arquivo: {0} (mais recentes primeiro)' -f $arquivo.FullName))
    $saida.Add('')
    foreach ($l in $linhas) {
        try {
            $o = ConvertFrom-Json -InputObject $l
            $saida.Add(('{0} | {1,-18} | {2,-9} | {3,-12} | {4}{5}' -f $o.DataHora, $o.Funcao, $o.Resultado, $o.Elevacao,
                $(if ($o.CodigoErro) { '[{0}] ' -f $o.CodigoErro } else { '' }), $o.Mensagem))
        }
        catch { $saida.Add($l) }
    }
    return New-ResultadoAcao -Status Sucesso -Mensagem ('Exibindo as últimas {0} linha(s) do log.' -f $linhas.Count) -Saida ($saida -join [Environment]::NewLine)
}

#endregion

Export-ModuleMember -Function *
