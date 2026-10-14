@echo off
rem ======================================================================
rem  SUPORTE TI - EVEN  (versao melhorada da BAT original)
rem
rem  Basta dar dois cliques. Funciona para usuarios e para a TI.
rem  O menu fica aqui em cima; as acoes ficam no trecho PowerShell no final
rem  deste mesmo arquivo (depois do marcador POWERSHELL).
rem
rem  Para mudar servidores, pastas ou impressoras: edite o bloco
rem  "CONFIGURACAO" no final do arquivo (Bloco de Notas, salvar como UTF-8).
rem ======================================================================
setlocal
title SUPORTE TI - EVEN
color 0B
set "SUPORTE_BAT=%~f0"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

rem Quando o proprio script se reabre como administrador
if /i "%~1"=="IMPRESSORAS" ( call :PS IMPRESSORAS & pause & exit /b )
if /i "%~1"=="LIMPEZAWINDOWS" ( call :PS LIMPEZAWINDOWS & pause & exit /b )

:MENU
cls
echo ===========================================
echo          SUPORTE TI - EVEN
echo ===========================================
echo.
echo  1 - Atualizar credencial do Cubo
echo  2 - Mapear pastas da Even
echo  3 - Configurar credencial do AD   (TI)
echo  4 - Limpeza de arquivos temporarios
echo  5 - Mapear impressoras
echo  6 - Abrir Active Directory        (TI)
echo.
echo  0 - Sair
echo.
echo ===========================================
choice /c 1234560 /n /m "Digite a opcao: "
if errorlevel 7 goto FIM
if errorlevel 6 ( set "FUNCAO=ABRIRAD" & goto EXECUTA )
if errorlevel 5 ( set "FUNCAO=IMPRESSORAS" & goto EXECUTA )
if errorlevel 4 ( set "FUNCAO=LIMPEZA" & goto EXECUTA )
if errorlevel 3 ( set "FUNCAO=AD" & goto EXECUTA )
if errorlevel 2 ( set "FUNCAO=PASTAS" & goto EXECUTA )
if errorlevel 1 ( set "FUNCAO=CUBO" & goto EXECUTA )
goto MENU

:EXECUTA
cls
call :PS %FUNCAO%
echo.
pause
goto MENU

:PS
rem Executa a funcao no PowerShell. Nada digitado pelo usuario passa pelo cmd.
set "SUPORTE_FUNCAO=%~1"
"%PSEXE%" -NoProfile -NoLogo -Command "$t=[IO.File]::ReadAllText($env:SUPORTE_BAT,[Text.Encoding]::UTF8); $m='#'+'#POWERSHELL#'+'#'; $i=$t.IndexOf($m); if($i -lt 0){Write-Host 'Arquivo do suporte incompleto.'; exit 1}; Invoke-Expression $t.Substring($i)"
exit /b

:FIM
endlocal
exit /b

##POWERSHELL##
# ======================================================================
#  Parte PowerShell do SuporteTI-EVEN.bat — não execute separadamente.
# ======================================================================
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ------------------------- CONFIGURACAO -------------------------------
# Valores copiados da BAT antiga. TODO_VALIDAR: confirmar se ainda valem.
$Config = @{
    Dominio            = 'EVENSP'
    ServidorCubo       = 'SSPDW01'
    ServidoresArquivos = @('SSPFLSSYNC01', 'SSPFLSSYNC02')
    Pastas             = @(
        '\\sspflssync02\Arquivos\Jurídico\JURIDICO IMOBILIARIO\EMPREENDIMENTOS\IMOBILIÁRIA'
        '\\sspflssync01\Files\Comercial\Imobiliária'
    )
    ServidorAD         = 'SSPAD005'
    Impressoras        = @(
        @{ Nome = 'PB - BACKOFFICE';    IP = '192.168.7.34' }
        @{ Nome = 'COLOR - BACKOFFICE'; IP = '192.168.7.212' }
        @{ Nome = 'EVEN MORE';          IP = '192.168.7.80' }
        @{ Nome = 'EVEN VENDAS';        IP = '192.168.7.33' }
        @{ Nome = 'PARCERIAS';          IP = '192.168.7.31' }
    )
    # TODO_VALIDAR: este driver pode não imprimir bem em porta 9100 em
    # alguns modelos. Se for o caso, troque pelo driver do fabricante.
    DriverImpressora   = 'Microsoft IPP Class Driver'
    PortaImpressora    = 9100
    # Confere a senha no domínio antes de salvar (evita salvar senha errada).
    ValidarSenha       = $true
    TimeoutRedeMs      = 3000
}
# ----------------------------------------------------------------------

if (-not ('EvenBat.Nativo' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace EvenBat {
    public static class Nativo {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL {
            public int Flags; public int Type; public string TargetName; public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
            public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
        }
        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL c, int flags);
        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr c);
        [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr p);
        [DllImport("advapi32.dll", EntryPoint = "LogonUserW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LogonUser(string u, string d, IntPtr p, int type, int prov, out IntPtr token);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct NETRESOURCE { public int dwScope; public int dwType; public int dwDisplayType; public int dwUsage;
            public string lpLocalName; public string lpRemoteName; public string lpComment; public string lpProvider; }
        [DllImport("mpr.dll", EntryPoint = "WNetAddConnection2W", CharSet = CharSet.Unicode)]
        private static extern int WNetAddConnection2(ref NETRESOURCE r, string p, string u, int f);
        [DllImport("mpr.dll", EntryPoint = "WNetCancelConnection2W", CharSet = CharSet.Unicode)]
        private static extern int WNetCancelConnection2(string n, int f, bool force);

        // Grava a credencial (mesmo tipo do cmdkey /add), sem a senha virar texto.
        public static int Gravar(string alvo, string usuario, IntPtr senha, int chars) {
            CREDENTIAL c = new CREDENTIAL();
            c.Type = 2; c.TargetName = alvo; c.UserName = usuario;
            c.CredentialBlob = senha; c.CredentialBlobSize = chars * 2; c.Persist = 3;
            return CredWrite(ref c, 0) ? 0 : Marshal.GetLastWin32Error();
        }
        // Lê só o NOME do usuário salvo (nunca a senha).
        public static string Usuario(string alvo) {
            IntPtr p;
            if (!CredRead(alvo, 2, 0, out p)) return null;
            try { return ((CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL))).UserName; } finally { CredFree(p); }
        }
        public static int ValidarSenha(string usuario, string dominio, IntPtr senha) {
            IntPtr t;
            if (LogonUser(usuario, dominio, senha, 3, 0, out t)) { CloseHandle(t); return 0; }
            return Marshal.GetLastWin32Error();
        }
        public static int Conectar(string remoto) {
            NETRESOURCE r = new NETRESOURCE(); r.lpRemoteName = remoto;
            return WNetAddConnection2(ref r, null, null, 0);
        }
        public static int Desconectar(string remoto) { return WNetCancelConnection2(remoto, 0, true); }
    }
}
'@
}

# --------------------------- utilitários ------------------------------
function Mostrar-Ok    ([string]$t) { Write-Host ('  [OK]    ' + $t) -ForegroundColor Green }
function Mostrar-Aviso ([string]$t) { Write-Host ('  [AVISO] ' + $t) -ForegroundColor Yellow }
function Mostrar-Erro  ([string]$t) { Write-Host ('  [ERRO]  ' + $t) -ForegroundColor Red }
function Mostrar-Titulo([string]$t) {
    Write-Host ''
    Write-Host '==========================================='
    Write-Host ('  ' + $t)
    Write-Host '==========================================='
    Write-Host ''
}

function Registrar([string]$Funcao, [string]$Resultado, [string]$Detalhe = '') {
    # Log simples, SEM senha: %LOCALAPPDATA%\EVEN\SuporteTI\suporte.log
    try {
        $pasta = Join-Path $env:LOCALAPPDATA 'EVEN\SuporteTI'
        if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
        $linha = '{0} | {1}\{2} | {3} | {4} | {5} | {6}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $Funcao, $Resultado, $Detalhe
        Add-Content -LiteralPath (Join-Path $pasta 'suporte.log') -Value $linha -Encoding UTF8
    } catch { }
}

function Eh-Administrador {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Abrir-ComoAdministrador([string]$Funcao) {
    try {
        Start-Process -FilePath $env:SUPORTE_BAT -ArgumentList $Funcao -Verb RunAs
        Mostrar-Ok 'Uma nova janela foi aberta como administrador.'
    } catch {
        Mostrar-Aviso 'A permissão de administrador não foi concedida. Peça ajuda à TI.'
    }
}

function Texto-Erro([int]$c) {
    switch ($c) {
        5    { 'Acesso negado.' }
        53   { 'Servidor não encontrado. Verifique a rede ou a VPN.' }
        67   { 'Compartilhamento não encontrado.' }
        86   { 'Senha incorreta.' }
        1219 { 'Já existe conexão com este servidor usando outro usuário. Feche as pastas desse servidor ou faça logoff.' }
        1311 { 'O domínio não respondeu. Verifique a rede ou a VPN.' }
        1312 { 'O Windows não permitiu salvar a credencial (política de segurança).' }
        1326 { 'Usuário ou senha incorretos.' }
        1330 { 'A senha expirou. Troque a senha antes.' }
        1331 { 'A conta está desabilitada.' }
        1355 { 'Domínio não encontrado. Verifique a rede ou a VPN.' }
        1907 { 'A senha precisa ser trocada antes do primeiro uso.' }
        1909 { 'A conta está bloqueada. Procure a TI.' }
        default { 'Erro do Windows {0}.' -f $c }
    }
}

function Testar-Porta([string]$Destino, [int]$Porta) {
    $cliente = New-Object System.Net.Sockets.TcpClient
    try { return ($cliente.ConnectAsync($Destino, $Porta).Wait($Config.TimeoutRedeMs) -and $cliente.Connected) }
    catch { return $false }
    finally { $cliente.Close() }
}

function Ler-Usuario([string]$Rotulo) {
    # Aceita: usuario | DOMINIO\usuario | usuario@empresa. Vazio = voltar.
    while ($true) {
        $t = [string](Read-Host ('  {0} (Enter vazio para voltar)' -f $Rotulo))
        $t = $t.Trim().Trim('"').Trim("'").Trim()
        if (-not $t) { return $null }
        $sam = $t
        if ($t.Contains('\')) {
            $partes = $t.Split('\')
            if ($partes.Count -ne 2 -or $partes[0].Trim() -ne $Config.Dominio) {
                Mostrar-Erro ('Use uma conta do domínio {0}. Digite só o usuário, ex.: joao.silva' -f $Config.Dominio); continue
            }
            $sam = $partes[1].Trim()
        } elseif ($t.Contains('@')) {
            $sam = $t.Substring(0, $t.LastIndexOf('@')).Trim()
        }
        if ($sam.Length -lt 1 -or $sam.Length -gt 20 -or $sam -notmatch '^[^"/\\\[\]:;|=,+*?<>@\x00-\x1F]+$' -or $sam.EndsWith('.')) {
            Mostrar-Erro 'Usuário inválido. Digite só o usuário, ex.: joao.silva'; continue
        }
        $completo = '{0}\{1}' -f $Config.Dominio, $sam
        Write-Host ('  Usuário: {0}' -f $completo)
        return [pscustomobject]@{ Sam = $sam; Completo = $completo }
    }
}

function Ler-Senha {
    # Read-Host -AsSecureString mostra * e a senha nunca vira texto.
    $s = Read-Host '  Senha' -AsSecureString
    if ($s.Length -eq 0) { Mostrar-Erro 'Senha não informada.'; return $null }
    return $s
}

function Com-SenhaNaoGerenciada([Security.SecureString]$Senha, [scriptblock]$Bloco) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Senha)
    try { return (& $Bloco $ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

function Conferir-Senha($Usuario, [Security.SecureString]$Senha) {
    # Retorna $true para continuar, $false para parar.
    if (-not $Config.ValidarSenha) { return $true }
    Write-Host '  Conferindo usuário e senha no domínio...'
    $sam = $Usuario.Sam
    $codigo = Com-SenhaNaoGerenciada $Senha { param($p) [EvenBat.Nativo]::ValidarSenha($sam, $Config.Dominio, $p) }
    if ($codigo -eq 0 -or $codigo -eq 1385) { Mostrar-Ok 'Usuário e senha conferidos.'; return $true }
    if (@(86, 1326, 1327, 1330, 1331, 1907, 1909, 1793) -contains $codigo) {
        Mostrar-Erro (Texto-Erro $codigo)
        Mostrar-Aviso 'Nada foi alterado. Atenção: várias tentativas erradas bloqueiam a conta.'
        return $false
    }
    Mostrar-Aviso ('Não foi possível conferir a senha agora ({0}). A credencial será salva mesmo assim.' -f (Texto-Erro $codigo))
    return $true
}

function Salvar-Credencial([string]$Alvo, $Usuario, [Security.SecureString]$Senha) {
    $completo = $Usuario.Completo
    $chars = $Senha.Length
    $codigo = Com-SenhaNaoGerenciada $Senha { param($p) [EvenBat.Nativo]::Gravar($Alvo, $completo, $p, $chars) }
    if ($codigo -ne 0) { Mostrar-Erro ('{0}: credencial NÃO salva. {1}' -f $Alvo, (Texto-Erro $codigo)); return $false }
    if ([EvenBat.Nativo]::Usuario($Alvo) -ne $completo) { Mostrar-Erro ('{0}: não foi possível confirmar a credencial.' -f $Alvo); return $false }
    Mostrar-Ok ('{0}: credencial salva.' -f $Alvo)
    return $true
}

function Testar-Acesso([string]$Servidor) {
    # Encerra a sessão antiga (que guarda a senha anterior) e testa a nova.
    [void][EvenBat.Nativo]::Desconectar(('\\{0}\IPC$' -f $Servidor))
    if (-not (Testar-Porta $Servidor 445)) { Mostrar-Aviso ('{0}: servidor fora do ar ou sem rede/VPN. A credencial ficou salva.' -f $Servidor); return $true }
    $c = [EvenBat.Nativo]::Conectar(('\\{0}\IPC$' -f $Servidor))
    if ($c -eq 0) { Mostrar-Ok ('{0}: acesso confirmado.' -f $Servidor); return $true }
    Mostrar-Erro ('{0}: {1}' -f $Servidor, (Texto-Erro $c))
    return $false
}

function Fluxo-Credencial([string]$Rotulo, [string[]]$Servidores, [bool]$TestarAcesso) {
    $usuario = Ler-Usuario $Rotulo
    if (-not $usuario) { Mostrar-Aviso 'Cancelado.'; return $false }
    $senha = Ler-Senha
    if (-not $senha) { return $false }
    try {
        if (-not (Conferir-Senha $usuario $senha)) { return $false }
        $ok = $true
        foreach ($s in $Servidores) {
            if (-not (Salvar-Credencial $s $usuario $senha)) { $ok = $false; continue }
            if ($TestarAcesso -and -not (Testar-Acesso $s)) { $ok = $false }
        }
        return $ok
    } finally { $senha.Dispose() }
}

# ----------------------------- funções --------------------------------
function Acao-Cubo {
    Mostrar-Titulo 'Atualizar credencial do Cubo'
    $ok = Fluxo-Credencial 'Usuário' @($Config.ServidorCubo) $false
    if ($ok) { Write-Host ''; Mostrar-Ok 'Pronto. Feche e abra de novo o Excel/relatório do Cubo.' }
    Registrar 'Cubo' $(if ($ok) { 'OK' } else { 'FALHA' })
}

function Acao-Pastas {
    Mostrar-Titulo 'Mapear pastas da Even'
    $ok = Fluxo-Credencial 'Usuário' $Config.ServidoresArquivos $true
    if (-not $ok) { Mostrar-Aviso 'As pastas não foram abertas porque a credencial não foi aceita.'; Registrar 'Pastas' 'FALHA'; return }
    Write-Host ''
    $falhas = 0
    foreach ($p in $Config.Pastas) {
        $nome = Split-Path $p -Leaf
        if (Test-Path -LiteralPath $p) {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $p)
            Mostrar-Ok ('Pasta aberta: {0}' -f $nome)
        } else {
            $falhas++
            Mostrar-Erro ('Pasta não encontrada ou sem permissão: {0}' -f $nome)
        }
    }
    Registrar 'Pastas' $(if ($falhas) { 'PARCIAL' } else { 'OK' }) ('pastas com falha: {0}' -f $falhas)
}

function Acao-CredencialAD {
    Mostrar-Titulo 'Configurar credencial do AD (TI)'
    $ok = Fluxo-Credencial 'Usuário de suporte' @($Config.ServidorAD) $true
    if ($ok) { Write-Host ''; Mostrar-Ok 'Pronto. Use a opção 6 para abrir o Active Directory.' }
    Registrar 'CredencialAD' $(if ($ok) { 'OK' } else { 'FALHA' })
}

function Limpar-Pasta([string]$Pasta) {
    # Apaga só DENTRO da pasta, sem seguir atalhos/junções. Arquivo em uso é pulado.
    $r = @{ Removidos = 0; EmUso = 0; SemPermissao = 0; Bytes = [long]0 }
    $raiz = [IO.Path]::GetFullPath($Pasta).TrimEnd('\')
    if (-not [IO.Directory]::Exists($raiz) -or [IO.Path]::GetPathRoot($raiz).TrimEnd('\') -eq $raiz) { return $r }
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($raiz)
    $pastas = New-Object System.Collections.Generic.List[string]
    while ($pilha.Count -gt 0) {
        $dir = $pilha.Pop()
        try { $itens = (New-Object IO.DirectoryInfo($dir)).GetFileSystemInfos() } catch { $r.SemPermissao++; continue }
        foreach ($i in $itens) {
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($i -is [IO.DirectoryInfo]) { $pastas.Add($i.FullName); $pilha.Push($i.FullName); continue }
            try {
                $tam = $i.Length
                if ($i.IsReadOnly) { $i.IsReadOnly = $false }
                $i.Delete(); $r.Removidos++; $r.Bytes += $tam
            }
            catch [System.UnauthorizedAccessException] { $r.SemPermissao++ }
            catch { $r.EmUso++ }
        }
    }
    foreach ($d in ($pastas | Sort-Object Length -Descending)) { try { [IO.Directory]::Delete($d, $false) } catch { } }
    return $r
}

function Mostrar-Limpeza([string]$Rotulo, $r) {
    Mostrar-Ok ('{0}: {1} arquivo(s) removido(s) ({2:N1} MB), {3} em uso (ignorados), {4} sem permissão.' -f
        $Rotulo, $r.Removidos, ($r.Bytes / 1MB), $r.EmUso, $r.SemPermissao)
}

function Acao-LimpezaWindows {
    Mostrar-Titulo 'Limpeza dos temporários do Windows'
    if (-not (Eh-Administrador)) { Mostrar-Erro 'Esta parte precisa de administrador.'; return }
    $r = Limpar-Pasta (Join-Path $env:SystemRoot 'Temp')
    Mostrar-Limpeza 'Temporários do Windows' $r
    Registrar 'LimpezaWindows' 'OK' ('removidos={0}' -f $r.Removidos)
}

function Acao-Limpeza {
    Mostrar-Titulo 'Limpeza de arquivos temporários'
    Write-Host '  Serão apagados: seus arquivos temporários e a Lixeira.'
    Write-Host '  Itens da Lixeira NÃO poderão ser recuperados. Arquivos em uso serão preservados.'
    Write-Host ''
    if ((Read-Host '  Confirma? (S/N)') -notmatch '^[sS]') { Mostrar-Aviso 'Cancelado.'; return }
    Write-Host ''

    $r = Limpar-Pasta ([IO.Path]::GetTempPath())
    Mostrar-Limpeza 'Temporários do usuário' $r

    try {
        $qtd = (New-Object -ComObject Shell.Application).NameSpace(10).Items().Count
        if ($qtd -eq 0) { Mostrar-Ok 'Lixeira: já estava vazia.' }
        else { Clear-RecycleBin -Force -ErrorAction Stop; Mostrar-Ok ('Lixeira: {0} item(ns) removido(s).' -f $qtd) }
    } catch { Mostrar-Aviso 'Lixeira: não foi possível esvaziar.' }

    if (Eh-Administrador) {
        Mostrar-Limpeza 'Temporários do Windows' (Limpar-Pasta (Join-Path $env:SystemRoot 'Temp'))
    } else {
        Mostrar-Aviso 'Temporários do Windows: não limpos (precisa de administrador).'
        if ((Read-Host '  Limpar também como administrador? (S/N)') -match '^[sS]') { Abrir-ComoAdministrador 'LIMPEZAWINDOWS' }
    }
    Registrar 'Limpeza' 'OK' ('removidos={0}; em uso={1}' -f $r.Removidos, $r.EmUso)
}

function Instalar-Impressora($Imp) {
    # Retorna 'OK', 'JA' ou o texto do erro.
    $nome = $Imp.Nome; $ip = $Imp.IP; $porta = 'IP_' + $ip
    if (@(Get-Printer) | Where-Object { $_.Name -eq $nome }) { return 'JA' }
    if (-not (Testar-Porta $ip $Config.PortaImpressora)) { return 'a impressora não respondeu na rede (ligada? rede da empresa?)' }
    if (-not (@(Get-PrinterDriver) | Where-Object { $_.Name -eq $Config.DriverImpressora })) { return ('driver "{0}" não instalado neste computador' -f $Config.DriverImpressora) }
    $criouPorta = $false
    try {
        $existente = @(Get-PrinterPort) | Where-Object { $_.Name -eq $porta } | Select-Object -First 1
        if (-not $existente) {
            Add-PrinterPort -Name $porta -PrinterHostAddress $ip -PortNumber $Config.PortaImpressora -ErrorAction Stop
            $criouPorta = $true
        }
        Add-Printer -Name $nome -PortName $porta -DriverName $Config.DriverImpressora -ErrorAction Stop
        if (-not (@(Get-Printer) | Where-Object { $_.Name -eq $nome -and $_.PortName -eq $porta })) { throw 'impressora não apareceu após instalar' }
        return 'OK'
    } catch {
        if ($criouPorta) { try { Remove-PrinterPort -Name $porta -ErrorAction Stop } catch { } }
        return ('o Windows recusou a instalação ({0})' -f $_.Exception.Message)
    }
}

function Acao-Impressoras {
    Mostrar-Titulo 'Mapear impressoras'
    $lista = $Config.Impressoras
    for ($i = 0; $i -lt $lista.Count; $i++) { Write-Host ('  {0} - {1}' -f ($i + 1), $lista[$i].Nome) }
    Write-Host '  T - Instalar todas'
    Write-Host '  0 - Voltar'
    Write-Host ''
    $op = ([string](Read-Host '  Opção')).Trim()
    if ($op -eq '0' -or -not $op) { return }
    if ($op -match '^[tT]$') { $escolhidas = $lista }
    elseif ($op -match '^\d+$' -and [int]$op -ge 1 -and [int]$op -le $lista.Count) { $escolhidas = @($lista[[int]$op - 1]) }
    else { Mostrar-Erro 'Opção inválida.'; return }

    $spooler = Get-Service -Name Spooler
    if ($spooler.Status -ne 'Running') { Mostrar-Erro 'O serviço de impressão (Spooler) está parado. Reinicie o computador ou chame a TI.'; return }

    $faltando = @($escolhidas | Where-Object { $n = $_.Nome; -not (@(Get-Printer) | Where-Object { $_.Name -eq $n }) })
    if ($faltando.Count -gt 0 -and -not (Eh-Administrador)) {
        foreach ($imp in $escolhidas) { if ($faltando -notcontains $imp) { Mostrar-Ok ('{0}: já estava instalada.' -f $imp.Nome) } }
        Mostrar-Aviso 'Instalar impressora precisa de administrador.'
        if ((Read-Host '  Abrir como administrador agora? (S/N)') -match '^[sS]') { Abrir-ComoAdministrador 'IMPRESSORAS' }
        return
    }

    Write-Host ''
    $ok = 0; $primeiraFalha = $null
    foreach ($imp in $escolhidas) {
        Write-Host ('  Instalando {0}...' -f $imp.Nome)
        $r = Instalar-Impressora $imp
        if ($r -eq 'OK') { $ok++; Mostrar-Ok ('{0}: instalada.' -f $imp.Nome) }
        elseif ($r -eq 'JA') { $ok++; Mostrar-Ok ('{0}: já estava instalada.' -f $imp.Nome) }
        else { Mostrar-Erro ('{0}: {1}' -f $imp.Nome, $r); if (-not $primeiraFalha) { $primeiraFalha = $imp } }
        Registrar 'Impressora' $(if ($r -eq 'OK' -or $r -eq 'JA') { 'OK' } else { 'FALHA' }) ('{0}: {1}' -f $imp.Nome, $r)
    }
    $falhas = $escolhidas.Count - $ok
    Write-Host ''
    Write-Host ('  Resumo: {0} pronta(s), {1} com problema.' -f $ok, $falhas)
    if ($primeiraFalha) {
        Set-Clipboard -Value $primeiraFalha.IP
        Mostrar-Aviso ('Abrindo o painel de impressoras para instalar manualmente. O IP de "{0}" foi copiado (Ctrl+V).' -f $primeiraFalha.Nome)
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\control.exe') -ArgumentList 'printers'
    }
}

function Acao-AbrirAD {
    $srv = $Config.ServidorAD
    Mostrar-Titulo ('Abrir Active Directory - {0}' -f $srv)
    $sistema = if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { Join-Path $env:SystemRoot 'Sysnative' } else { Join-Path $env:SystemRoot 'System32' }
    $dsa = Join-Path $sistema 'dsa.msc'
    if (-not (Test-Path $dsa) -or -not (Test-Path (Join-Path $sistema 'dsadmin.dll'))) {
        Mostrar-Erro 'RSAT não instalado (console dsa.msc não encontrado).'
        Write-Host '  Instale em: Configurações > Sistema > Recursos opcionais >'
        Write-Host '  "RSAT: Active Directory Domain Services e Ferramentas LDS".'
        Registrar 'AbrirAD' 'FALHA' 'RSAT ausente'; return
    }
    if (-not [EvenBat.Nativo]::Usuario($srv)) {
        Mostrar-Erro 'Credencial do AD não encontrada. Configure primeiro pela opção 3.'
        Registrar 'AbrirAD' 'FALHA' 'sem credencial'; return
    }
    Mostrar-Ok 'Credencial encontrada.'
    if (-not (Testar-Porta $srv 389)) { Mostrar-Erro 'O servidor do AD não respondeu. Verifique a rede ou a VPN.'; Registrar 'AbrirAD' 'FALHA' 'sem rede'; return }
    if (-not (Testar-Acesso $srv)) { Mostrar-Aviso 'Atualize a credencial pela opção 3.'; Registrar 'AbrirAD' 'FALHA' 'credencial recusada'; return }
    Start-Process -FilePath (Join-Path $sistema 'mmc.exe') -ArgumentList @(('"{0}"' -f $dsa), ('/server={0}' -f $srv))
    Mostrar-Ok 'Active Directory aberto.'
    Registrar 'AbrirAD' 'OK'
}

# ------------------------------ início --------------------------------
try {
    switch ($env:SUPORTE_FUNCAO) {
        'CUBO'           { Acao-Cubo }
        'PASTAS'         { Acao-Pastas }
        'AD'             { Acao-CredencialAD }
        'LIMPEZA'        { Acao-Limpeza }
        'LIMPEZAWINDOWS' { Acao-LimpezaWindows }
        'IMPRESSORAS'    { Acao-Impressoras }
        'ABRIRAD'        { Acao-AbrirAD }
        default          { Mostrar-Erro 'Função desconhecida.' }
    }
} catch {
    Mostrar-Erro 'Ocorreu um erro inesperado. Tente de novo; se continuar, avise a TI.'
    Registrar $env:SUPORTE_FUNCAO 'ERRO' $_.Exception.Message
}
