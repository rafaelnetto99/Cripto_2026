#Requires -Version 5.1
<#
.SYNOPSIS
    Central de Suporte TI - EVEN — executor de tarefas ADMINISTRATIVAS.

.DESCRIPTION
    Arquivo: SuporteTI.Elevado.ps1 (material para HOMOLOGAÇÃO)

    Chamado SOMENTE pela aplicação principal, via UAC (Start-Process -Verb
    RunAs), para UMA tarefa por vez. A interface nunca roda elevada.

    Segurança:
      - aceita apenas ações de uma lista fixa (ValidateSet) e Ids com
        formato restrito; nenhum texto livre do usuário chega aqui;
      - lê módulos e configuração da PRÓPRIA pasta (nunca de caminho
        recebido por parâmetro);
      - recusa rodar fora de pasta protegida (configurável);
      - grava o resultado com FileMode.CreateNew num arquivo de nome
        aleatório, recusando links/arquivos já existentes;
      - não recebe, não pede e não grava senhas.

.PARAMETER Acao
    LimparTempWindows | InstalarImpressoras | InstalarRSAT

.PARAMETER Ids
    Ids de impressoras separados por vírgula (só para InstalarImpressoras).

.PARAMETER ArquivoResultado
    ...\EVEN\SuporteTI\run\resultado_<GUID>.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('LimparTempWindows', 'InstalarImpressoras', 'InstalarRSAT')]
    [string]$Acao,

    [ValidatePattern('^[A-Za-z0-9_]{1,40}(,[A-Za-z0-9_]{1,40}){0,49}$')]
    [string]$Ids = '',

    [Parameter(Mandatory)]
    [string]$ArquivoResultado
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Códigos de saída: 0 = resultado gravado; 2 = parâmetro inválido;
# 3 = não foi possível gravar o resultado.

function Test-ArquivoResultadoSeguro {
    param([string]$Caminho)
    if (-not [IO.Path]::IsPathRooted($Caminho)) { return $false }
    if ($Caminho -match '\.\.') { return $false }
    if ([IO.Path]::GetFileName($Caminho) -notmatch '^resultado_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.json$') { return $false }
    $pasta = [IO.Path]::GetDirectoryName($Caminho)
    if ($pasta -notmatch '\\EVEN\\SuporteTI\\run$') { return $false }
    if (-not [IO.Directory]::Exists($pasta)) { return $false }
    if (([IO.File]::GetAttributes($pasta) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    if ([IO.File]::Exists($Caminho) -or [IO.Directory]::Exists($Caminho)) { return $false }
    return $true
}

function Write-ResultadoSeguro {
    param([object]$Objeto, [string]$Caminho)
    $json = ConvertTo-Json -InputObject $Objeto -Depth 6
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    # CreateNew falha se o arquivo (ou um link com esse nome) já existir.
    $fluxo = New-Object System.IO.FileStream($Caminho, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fluxo.Write($bytes, 0, $bytes.Length) } finally { $fluxo.Dispose() }
}

if (-not (Test-ArquivoResultadoSeguro -Caminho $ArquivoResultado)) { exit 2 }

$resultado = $null
try {
    foreach ($m in 'Core', 'Credenciais', 'Rede', 'Limpeza', 'Impressoras', 'ActiveDirectory') {
        Import-Module -Name (Join-Path $PSScriptRoot ('modules\SuporteTI.{0}.psm1' -f $m)) -Global -Force -DisableNameChecking
    }
    $config = Import-SuporteConfig -Caminho (Join-Path $PSScriptRoot 'config\SuporteTI.config.psd1')
    [void](Initialize-SuporteContexto -Config $config -AppRoot $PSScriptRoot -Fila $null)

    if (-not (Test-Administrador)) {
        $resultado = New-ResultadoAcao -Status Falha -Elevacao 'Negada' -Mensagem 'O processo não está elevado.'
    }
    elseif ($config.Aplicacao.ExigirPastaProtegidaParaElevacao -and -not (Test-PastaProtegida -Pasta $PSScriptRoot -Config $config)) {
        $resultado = New-ResultadoAcao -Status Falha -Elevacao 'Bloqueada' `
            -Mensagem 'Execução elevada recusada: a ferramenta não está numa pasta protegida.' -Detalhes ('Pasta: {0}' -f $PSScriptRoot)
    }
    else {
        switch ($Acao) {
            'LimparTempWindows' {
                if (-not $config.Limpeza.PermitirTempWindows) {
                    $resultado = New-ResultadoAcao -Status Falha -Elevacao 'Elevado' -Mensagem 'Limpeza do Temp do Windows desativada na configuração.'
                }
                else {
                    $estatistica = Clear-PastaTemporaria -Tipo Windows
                    $resultado = New-ResultadoAcao -Status Sucesso -Elevacao 'Elevado' -Mensagem 'Temporários do Windows processados.' -Dados $estatistica
                }
            }
            'InstalarImpressoras' {
                if (-not $Ids) {
                    $resultado = New-ResultadoAcao -Status Falha -Elevacao 'Elevado' -Mensagem 'Nenhuma impressora informada.'
                }
                else {
                    $lista = Install-Impressoras -Ids ($Ids -split ',')
                    $resultado = New-ResultadoAcao -Status Sucesso -Elevacao 'Elevado' -Mensagem 'Instalação processada.' -Dados @($lista)
                }
            }
            'InstalarRSAT' {
                $resultado = Install-RsatAD
            }
        }
    }
    Write-SuporteLog -Funcao ('Elevado.{0}' -f $Acao) -Resultado $resultado.Status -Mensagem (@($resultado.Mensagem, $resultado.Detalhes) -join ' | ') -Elevacao 'Elevado' -CodigoErro $resultado.CodigoErro
}
catch {
    $resultado = [pscustomobject]@{
        Status = 'Falha'; Mensagem = 'Erro na tarefa administrativa.'; Recomendacao = 'Envie os detalhes técnicos à TI.'
        Itens = @(); Detalhes = ('{0}: {1}' -f $_.Exception.GetType().FullName, $_.Exception.Message)
        CodigoErro = ''; Elevacao = 'Elevado'; PosAcao = $null; Saida = ''; Dados = $null
    }
}

try {
    Write-ResultadoSeguro -Objeto $resultado -Caminho $ArquivoResultado
    exit 0
}
catch {
    exit 3
}
