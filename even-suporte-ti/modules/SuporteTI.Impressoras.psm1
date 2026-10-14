<#
    Arquivo : modules\SuporteTI.Impressoras.psm1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Instalação de impressoras por porta TCP/IP (RAW 9100 ou LPR).

    Diferenças em relação à BAT:
      - a existência é conferida por OBJETO (Get-Printer), não por texto
        ou código de saída do powershell.exe;
      - porta existente é reaproveitada só se apontar para o MESMO IP;
      - driver é conferido antes (e pode ser instalado via .inf);
      - o resultado é conferido depois (nome, porta e driver);
      - se a impressora falhar, a porta criada nesta tentativa é removida;
      - em "instalar todas", cada impressora tem resultado próprio.

    Criar porta TCP/IP e instalar driver exige ADMINISTRADOR (regras do
    spooler após PrintNightmare). A instalação roda elevada via
    SuporteTI.Elevado.ps1 quando necessário.
#>
Set-StrictMode -Version 2.0

function Get-ImpressoraConfig {
    param([Parameter(Mandatory)][string]$Id)
    $config = (Get-SuporteContexto).Config
    $imp = @($config.Impressoras) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $imp) { throw ('Impressora não configurada: {0}' -f $Id) }
    return $imp
}

function Get-ImpressorasHabilitadas {
    $config = (Get-SuporteContexto).Config
    return @(@($config.Impressoras) | Where-Object { $_.Habilitada })
}

function New-ResultadoImpressora {
    param([hashtable]$Impressora, [string]$Estado, [string]$Texto, [string]$Detalhe = '')
    return [pscustomobject]@{
        Id      = [string]$Impressora.Id
        Nome    = [string]$Impressora.Nome
        IP      = [string]$Impressora.IP
        Estado  = $Estado         # Instalada | JaExistia | Falhou | Ignorada | Pendente
        Texto   = $Texto
        Detalhe = (Protect-TextoSensivel $Detalhe)
    }
}

function Test-SpoolerAtivo {
    try {
        $s = Get-Service -Name Spooler -ErrorAction Stop
        return ($s.Status -eq 'Running')
    }
    catch { return $false }
}

function Get-ImpressoraInstalada {
    <# Busca exata por nome (sem curingas) — devolve o objeto ou $null. #>
    param([Parameter(Mandatory)][string]$Nome)
    return (@(Get-Printer -ErrorAction Stop) | Where-Object { $_.Name -eq $Nome } | Select-Object -First 1)
}

function Get-EstadoImpressora {
    <#
        Pré-checagem SEM privilégio administrativo: decide se a impressora
        já existe, se está inacessível ou se precisa ser instalada.
    #>
    param([Parameter(Mandatory)][hashtable]$Impressora)
    $config = (Get-SuporteContexto).Config
    $nome = [string]$Impressora.Nome

    foreach ($chave in 'Nome', 'IP', 'NomePorta', 'Driver') {
        if (Test-ValorPendente $Impressora[$chave]) {
            return New-ResultadoImpressora -Impressora $Impressora -Estado 'Falhou' `
                -Texto ('✖ {0}: ainda não configurada pela TI.' -f $nome) -Detalhe ('CONFIG_PENDENTE Impressoras.{0}.{1}' -f $Impressora.Id, $chave)
        }
    }
    if (-not (Test-SpoolerAtivo)) {
        return New-ResultadoImpressora -Impressora $Impressora -Estado 'Falhou' `
            -Texto ('✖ {0}: o serviço de impressão (Spooler) não está em execução.' -f $nome) -Detalhe 'Spooler parado'
    }

    $existente = Get-ImpressoraInstalada -Nome $nome
    if ($existente) {
        if ($existente.PortName -eq [string]$Impressora.NomePorta) {
            return New-ResultadoImpressora -Impressora $Impressora -Estado 'JaExistia' -Texto ('✔ {0}: já estava instalada.' -f $nome)
        }
        return New-ResultadoImpressora -Impressora $Impressora -Estado 'Falhou' `
            -Texto ('⚠ {0}: já existe uma impressora com este nome usando outra porta. Procure a TI.' -f $nome) `
            -Detalhe ('Porta atual: {0}; esperada: {1}' -f $existente.PortName, $Impressora.NomePorta)
    }

    $porta = Test-PortaTcp -Destino ([string]$Impressora.IP) -Porta ([int]$Impressora.Porta)
    if (-not $porta.Ok -and -not $config.InstalarImpressoraInacessivel) {
        return New-ResultadoImpressora -Impressora $Impressora -Estado 'Ignorada' `
            -Texto ('⚠ {0}: a impressora não respondeu na rede. Verifique se está ligada e se você está na rede da empresa.' -f $nome) `
            -Detalhe ('TCP {0}:{1} -> {2}' -f $Impressora.IP, $Impressora.Porta, $porta.Motivo)
    }
    return New-ResultadoImpressora -Impressora $Impressora -Estado 'Pendente' -Texto ('{0}: será instalada.' -f $nome)
}

function Install-DriverImpressora {
    <# Garante que o driver exista; instala via pnputil + Add-PrinterDriver se houver .inf configurado. #>
    param([Parameter(Mandatory)][hashtable]$Impressora)
    $config = (Get-SuporteContexto).Config
    $driver = [string]$Impressora.Driver

    if (@(Get-PrinterDriver -ErrorAction Stop) | Where-Object { $_.Name -eq $driver }) {
        return [pscustomobject]@{ Ok = $true; Detalhe = 'Driver já presente' }
    }

    $inf = [string]$Impressora.DriverInf
    if (-not $inf -or (Test-ValorPendente $inf)) {
        return [pscustomobject]@{ Ok = $false; Detalhe = ('Driver "{0}" não está instalado e nenhum DriverInf foi configurado.' -f $driver) }
    }
    if (-not [IO.Path]::IsPathRooted($inf)) { $inf = Join-Path (Get-SuporteContexto).AppRoot $inf }
    if (-not (Test-Path -LiteralPath $inf -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Detalhe = ('Arquivo .inf não encontrado: {0}' -f $inf) }
    }
    if ($config.Aplicacao.ExigirPastaProtegidaParaElevacao -and -not (Test-PastaProtegida -Pasta (Split-Path -Parent $inf) -Config $config)) {
        return [pscustomobject]@{ Ok = $false; Detalhe = 'O .inf do driver precisa estar em pasta protegida (Program Files ou PastasConfiaveis).' }
    }

    Send-Progresso -Texto ('Instalando driver "{0}"...' -f $driver)
    $pnputil = Join-Path (Get-CaminhoSistema) 'pnputil.exe'
    $proc = Start-Process -FilePath $pnputil -ArgumentList @('/add-driver', ('"{0}"' -f $inf), '/install') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    # 0 = ok; 259 = nada novo a instalar; 3010 = ok, requer reinício
    if (@(0, 259, 3010) -notcontains $proc.ExitCode) {
        return [pscustomobject]@{ Ok = $false; Detalhe = ('pnputil retornou {0}' -f $proc.ExitCode) }
    }
    Add-PrinterDriver -Name $driver -ErrorAction Stop
    if (-not (@(Get-PrinterDriver -ErrorAction Stop) | Where-Object { $_.Name -eq $driver })) {
        return [pscustomobject]@{ Ok = $false; Detalhe = 'Driver não aparece após a instalação (nome no .inf diferente do configurado?).' }
    }
    return [pscustomobject]@{ Ok = $true; Detalhe = ('Driver instalado via pnputil ({0})' -f $proc.ExitCode) }
}

function Install-ImpressoraTcpIp {
    <# Instala UMA impressora. Exige processo elevado. Nunca lança exceção: devolve resultado. #>
    param([Parameter(Mandatory)][hashtable]$Impressora)

    $nome = [string]$Impressora.Nome
    $previa = Get-EstadoImpressora -Impressora $Impressora
    if ($previa.Estado -ne 'Pendente') { return $previa }

    if (-not (Test-Administrador)) {
        return New-ResultadoImpressora -Impressora $Impressora -Estado 'Falhou' `
            -Texto ('✖ {0}: a instalação exige permissão de administrador.' -f $nome) -Detalhe 'Processo não elevado'
    }

    $nomePorta = [string]$Impressora.NomePorta
    $ip = [string]$Impressora.IP
    $driver = [string]$Impressora.Driver
    $portaCriada = $false

    try {
        Send-Progresso -Texto ('Instalando {0}...' -f $nome)

        $drv = Install-DriverImpressora -Impressora $Impressora
        if (-not $drv.Ok) {
            return New-ResultadoImpressora -Impressora $Impressora -Estado 'Falhou' `
                -Texto ('✖ {0}: driver da impressora não disponível neste computador.' -f $nome) -Detalhe $drv.Detalhe
        }

        $portaExistente = @(Get-PrinterPort -ErrorAction Stop) | Where-Object { $_.Name -eq $nomePorta } | Select-Object -First 1
        if ($portaExistente) {
            $enderecoPorta = ''
            if ($portaExistente.PSObject.Properties['PrinterHostAddress'] -and $portaExistente.PrinterHostAddress) { $enderecoPorta = [string]$portaExistente.PrinterHostAddress }
            elseif ($portaExistente.PSObject.Properties['LprHostAddress'] -and $portaExistente.LprHostAddress) { $enderecoPorta = [string]$portaExistente.LprHostAddress }
            if ($enderecoPorta -and $enderecoPorta -ne $ip) {
                return New-ResultadoImpressora -Impressora $Impressora -Estado 'Falhou' `
                    -Texto ('✖ {0}: já existe uma porta com este nome apontando para outro endereço. Procure a TI.' -f $nome) `
                    -Detalhe ('Porta {0} aponta para {1}; esperado {2}' -f $nomePorta, $enderecoPorta, $ip)
            }
        }
        else {
            if ([string]$Impressora.Protocolo -eq 'LPR') {
                $fila = [string]$Impressora.FilaLpr
                if (-not $fila -or (Test-ValorPendente $fila)) { throw 'FilaLpr não configurada para impressora LPR.' }
                Add-PrinterPort -Name $nomePorta -LprHostAddress $ip -LprQueueName $fila -ErrorAction Stop
            }
            else {
                Add-PrinterPort -Name $nomePorta -PrinterHostAddress $ip -PortNumber ([int]$Impressora.Porta) -ErrorAction Stop
            }
            $portaCriada = $true
        }

        $parametros = @{ Name = $nome; PortName = $nomePorta; DriverName = $driver; ErrorAction = 'Stop' }
        if (-not (Test-ValorPendente $Impressora.Localizacao)) { $parametros.Location = [string]$Impressora.Localizacao }
        Add-Printer @parametros

        # Conferência por objeto
        $instalada = Get-ImpressoraInstalada -Nome $nome
        if (-not $instalada -or $instalada.PortName -ne $nomePorta -or $instalada.DriverName -ne $driver) {
            throw 'A impressora não foi encontrada com a porta/driver esperados após a instalação.'
        }
        return New-ResultadoImpressora -Impressora $Impressora -Estado 'Instalada' -Texto ('✔ {0}: instalada com sucesso.' -f $nome) -Detalhe $drv.Detalhe
    }
    catch {
        $detalhe = Get-MensagemInterna $_.Exception
        if ($portaCriada) {
            # Desfaz a porta criada nesta tentativa para não deixar lixo.
            try {
                if (-not (@(Get-Printer -ErrorAction SilentlyContinue) | Where-Object { $_.PortName -eq $nomePorta })) {
                    Remove-PrinterPort -Name $nomePorta -ErrorAction Stop
                    $detalhe += ' | Porta criada nesta tentativa foi removida.'
                }
            }
            catch { $detalhe += (' | Não foi possível remover a porta: {0}' -f (Get-MensagemInterna $_.Exception)) }
        }
        return New-ResultadoImpressora -Impressora $Impressora -Estado 'Falhou' `
            -Texto ('✖ {0}: o Windows não aceitou instalar a impressora automaticamente.' -f $nome) -Detalhe $detalhe
    }
}

function Install-Impressoras {
    <# Instala uma lista de impressoras; uma falha não interrompe as demais. #>
    param([Parameter(Mandatory)][string[]]$Ids)
    $resultados = New-Object System.Collections.Generic.List[object]
    $total = $Ids.Count
    $n = 0
    foreach ($id in $Ids) {
        $n++
        Send-Progresso -Texto ('Impressora {0} de {1}...' -f $n, $total) -Percentual ([int](($n - 1) * 100 / [Math]::Max($total, 1)))
        try {
            $imp = Get-ImpressoraConfig -Id $id
            $resultados.Add((Install-ImpressoraTcpIp -Impressora $imp))
        }
        catch {
            $resultados.Add([pscustomobject]@{
                Id = $id; Nome = $id; IP = ''; Estado = 'Falhou'
                Texto = ('✖ {0}: erro inesperado.' -f $id); Detalhe = (Get-MensagemInterna $_.Exception)
            })
        }
    }
    return , $resultados.ToArray()
}

Export-ModuleMember -Function *
