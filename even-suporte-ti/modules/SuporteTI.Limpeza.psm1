<#
    Arquivo : modules\SuporteTI.Limpeza.psm1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Limpeza de temporários e Lixeira, com contagem separada de:
      removidos | em uso | sem permissão | recentes preservados | links ignorados

    Regras de segurança:
      - só apaga DENTRO das pastas permitidas (Temp do usuário e
        %SystemRoot%\Temp), calculadas pelo próprio sistema;
      - nunca segue links simbólicos/junções (não sai da pasta);
      - nunca apaga a própria pasta raiz;
      - erros não são escondidos: são contados e vão para o log.
#>
Set-StrictMode -Version 2.0

function Get-PastaTemporaria {
    param([Parameter(Mandatory)][ValidateSet('Usuario', 'Windows')][string]$Tipo)
    if ($Tipo -eq 'Usuario') {
        return [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    }
    return [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'Temp')).TrimEnd('\')
}

function New-EstatisticaLimpeza {
    param([string]$Rotulo, [string]$Pasta)
    return [pscustomobject]@{
        Rotulo          = $Rotulo
        Pasta           = $Pasta
        Executado       = $false
        Removidos       = 0
        PastasRemovidas = 0
        Bytes           = [long]0
        EmUso           = 0
        SemPermissao    = 0
        Recentes        = 0
        LinksIgnorados  = 0
        OutrosErros     = 0
        Observacao      = ''
    }
}

function Clear-PastaTemporaria {
    <#
        Remove o conteúdo da pasta temporária indicada. Retorna estatísticas.
        Temp do Windows exige processo elevado.
    #>
    param([Parameter(Mandatory)][ValidateSet('Usuario', 'Windows')][string]$Tipo)

    $config = (Get-SuporteContexto).Config
    $rotulo = if ($Tipo -eq 'Usuario') { 'Temporários do usuário' } else { 'Temporários do Windows' }
    $raiz = Get-PastaTemporaria -Tipo $Tipo
    $est = New-EstatisticaLimpeza -Rotulo $rotulo -Pasta $raiz

    # --- Travas de segurança -----------------------------------------
    $permitidas = @((Get-PastaTemporaria -Tipo Usuario), (Get-PastaTemporaria -Tipo Windows))
    if ($permitidas -notcontains $raiz) { throw ('Pasta fora da lista permitida: {0}' -f $raiz) }
    if (([IO.Path]::GetPathRoot($raiz)).TrimEnd('\') -eq $raiz) { throw 'Recusado: a pasta temporária aponta para a raiz de uma unidade.' }
    if ($raiz -ieq $env:SystemRoot.TrimEnd('\') -or $raiz -ieq ([Environment]::GetFolderPath('UserProfile')).TrimEnd('\')) {
        throw ('Recusado: a pasta temporária aponta para uma pasta do sistema/perfil ({0}).' -f $raiz)
    }
    if (-not [IO.Directory]::Exists($raiz)) {
        $est.Observacao = 'Pasta não encontrada.'
        $est.Executado = $true
        return $est
    }
    if (([IO.File]::GetAttributes($raiz) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('Recusado: a pasta temporária é um link/junção ({0}).' -f $raiz)
    }
    if ($Tipo -eq 'Windows' -and -not (Test-Administrador)) {
        $est.Observacao = 'Não executado: exige administrador.'
        return $est
    }

    $horas = 0
    [void][int]::TryParse([string]$config.Limpeza.IdadeMinimaHoras, [ref]$horas)
    $limite = (Get-Date).AddHours(-1 * $horas)

    Send-Progresso -Texto ('Limpando {0}...' -f $rotulo.ToLowerInvariant())

    # Percurso iterativo (sem recursão), sem seguir links.
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($raiz)
    $subpastas = New-Object System.Collections.Generic.List[string]
    $contador = 0

    while ($pilha.Count -gt 0) {
        $dir = $pilha.Pop()
        $entradas = $null
        try {
            $entradas = (New-Object IO.DirectoryInfo($dir)).GetFileSystemInfos()
        }
        catch [System.UnauthorizedAccessException] { $est.SemPermissao++; continue }
        catch { $est.OutrosErros++; continue }

        foreach ($e in $entradas) {
            $contador++
            if (($contador % 500) -eq 0) { Send-Progresso -Texto ('{0}: {1} itens analisados...' -f $rotulo, $contador) }

            if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                # Link simbólico/junção: não segue e não apaga o destino.
                $est.LinksIgnorados++
                continue
            }
            if ($e -is [IO.DirectoryInfo]) {
                $subpastas.Add($e.FullName)
                $pilha.Push($e.FullName)
                continue
            }

            $arquivo = [IO.FileInfo]$e
            if ($arquivo.LastWriteTime -gt $limite) { $est.Recentes++; continue }
            try {
                $tamanho = $arquivo.Length
                if ($arquivo.IsReadOnly) { $arquivo.IsReadOnly = $false }
                $arquivo.Delete()
                $est.Removidos++
                $est.Bytes += $tamanho
            }
            catch [System.UnauthorizedAccessException] { $est.SemPermissao++ }
            catch [System.IO.IOException] { $est.EmUso++ }
            catch { $est.OutrosErros++ }
        }
    }

    # Remove subpastas vazias, da mais profunda para a mais rasa.
    foreach ($d in ($subpastas | Sort-Object -Property Length -Descending)) {
        try {
            $info = New-Object IO.DirectoryInfo($d)
            if (-not $info.Exists) { continue }
            if ($info.CreationTime -gt $limite) { continue }
            if ($info.GetFileSystemInfos().Count -gt 0) { continue }
            $info.Delete($false)
            $est.PastasRemovidas++
        }
        catch [System.UnauthorizedAccessException] { $est.SemPermissao++ }
        catch [System.IO.IOException] { $est.EmUso++ }
        catch { $est.OutrosErros++ }
    }

    $est.Executado = $true
    return $est
}

function Clear-LixeiraUsuario {
    <# Esvazia a Lixeira do usuário atual (todas as unidades) via Shell API. #>
    $bytesAntes = [long]0
    $antes = [EvenSuporte.Nativo]::ItensLixeira([ref]$bytesAntes)
    if ($antes -eq 0) {
        return [pscustomobject]@{ Executado = $true; Removidos = 0; Bytes = [long]0; Restantes = 0; Codigo = ''; Observacao = 'A Lixeira já estava vazia.' }
    }

    Send-Progresso -Texto 'Esvaziando a Lixeira...'
    $hr = [EvenSuporte.Nativo]::EsvaziarLixeira()
    $bytesDepois = [long]0
    $depois = [EvenSuporte.Nativo]::ItensLixeira([ref]$bytesDepois)

    $removidos = if ($antes -ge 0 -and $depois -ge 0) { [Math]::Max(0, $antes - $depois) } else { -1 }
    $ok = ($hr -eq 0) -or ($depois -eq 0)
    return [pscustomobject]@{
        Executado  = $ok
        Removidos  = $removidos
        Bytes      = [Math]::Max([long]0, $bytesAntes - $bytesDepois)
        Restantes  = $depois
        Codigo     = ('0x{0:X8}' -f $hr)
        Observacao = $(if ($ok) { '' } else { 'O Windows não conseguiu esvaziar a Lixeira.' })
    }
}

function Format-Tamanho {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} bytes' -f $Bytes)
}

function Format-ResumoLimpeza {
    <# Texto amigável de uma estatística de pasta (aceita objeto vindo de JSON). #>
    param([Parameter(Mandatory)][object]$Estatistica)
    $e = $Estatistica
    if (-not $e.Executado) {
        $motivo = if ($e.Observacao) { $e.Observacao } else { 'Não executado.' }
        return ('⚠ {0}: {1}' -f $e.Rotulo, $motivo)
    }
    if ($e.Observacao) { return ('✔ {0}: {1}' -f $e.Rotulo, $e.Observacao) }
    $partes = @(
        ('{0} arquivo(s) removido(s) ({1})' -f $e.Removidos, (Format-Tamanho ([long]$e.Bytes))),
        ('{0} pasta(s) vazia(s) removida(s)' -f $e.PastasRemovidas),
        ('{0} em uso (ignorados)' -f $e.EmUso),
        ('{0} sem permissão' -f $e.SemPermissao),
        ('{0} recente(s) preservado(s)' -f $e.Recentes)
    )
    if ([int]$e.LinksIgnorados -gt 0) { $partes += ('{0} link(s) ignorado(s)' -f $e.LinksIgnorados) }
    if ([int]$e.OutrosErros -gt 0) { $partes += ('{0} outro(s) erro(s)' -f $e.OutrosErros) }
    return ('✔ {0}: {1}.' -f $e.Rotulo, ($partes -join '; '))
}

Export-ModuleMember -Function *
