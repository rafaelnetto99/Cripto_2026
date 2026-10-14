<#
    Arquivo : modules\SuporteTI.Core.psm1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Núcleo da aplicação:
      - tipos nativos Win32 (Gerenciador de Credenciais, LogonUser,
        conexões SMB, Lixeira, console);
      - leitura e validação da configuração centralizada;
      - contexto de execução, progresso e log de auditoria;
      - validação de entradas (usuário, servidor, IP, caminho UNC);
      - perfis de acesso e checagem de permissão;
      - testes de rede com timeout.

    Regra de segurança: nenhuma função deste módulo recebe senha em
    texto puro nem grava senha em log.
#>
Set-StrictMode -Version 2.0

$script:Contexto         = $null
$script:MarcadorPendente = 'TODO_VALIDAR'
$script:PerfisValidos    = @('Usuario', 'Tecnico', 'Administrador')

#region Tipos nativos (Win32) -------------------------------------------------
# Usamos a API do Windows diretamente em vez do cmdkey.exe/net.exe para:
#  - nunca colocar a senha na linha de comando de outro processo;
#  - receber códigos de erro exatos (ex.: 1326 = senha incorreta);
#  - não depender de texto de saída traduzido.
if (-not ('EvenSuporte.Nativo' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace EvenSuporte
{
    public static class Nativo
    {
        // ---------------- Gerenciador de Credenciais ----------------
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll")]
        private static extern void CredFree(IntPtr buffer);

        // Grava credencial. A senha chega como ponteiro para memória não
        // gerenciada (vinda de SecureString) e nunca vira System.String.
        public static int GravarCredencial(string destino, string usuario, IntPtr senha, int caracteres, int tipo, int persistencia)
        {
            if (senha == IntPtr.Zero || caracteres <= 0) return 87; // ERROR_INVALID_PARAMETER
            CREDENTIAL c = new CREDENTIAL();
            c.Type = tipo;
            c.TargetName = destino;
            c.UserName = usuario;
            c.CredentialBlob = senha;
            c.CredentialBlobSize = caracteres * 2;
            c.Persist = persistencia;
            if (!CredWrite(ref c, 0)) return Marshal.GetLastWin32Error();
            return 0;
        }

        // Confere se existe credencial para o destino e devolve SOMENTE o
        // nome do usuário (a senha de credenciais de domínio não é lida).
        public static int LerUsuarioCredencial(string destino, int tipo, out string usuario)
        {
            usuario = null;
            IntPtr p;
            if (!CredRead(destino, tipo, 0, out p)) return Marshal.GetLastWin32Error();
            try
            {
                CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
                usuario = c.UserName;
            }
            finally { CredFree(p); }
            return 0;
        }

        public static int ExcluirCredencial(string destino, int tipo)
        {
            if (!CredDelete(destino, tipo, 0)) return Marshal.GetLastWin32Error();
            return 0;
        }

        // ---------------- Validação de senha no domínio ----------------
        [DllImport("advapi32.dll", EntryPoint = "LogonUserW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LogonUser(string usuario, string dominio, IntPtr senha, int tipo, int provedor, out IntPtr token);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        // Logon de REDE (tipo 3): só valida a senha no controlador de
        // domínio; não abre sessão interativa. Retorna código Win32.
        public static int ValidarLogonRede(string usuario, string dominio, IntPtr senha)
        {
            IntPtr token;
            if (LogonUser(usuario, dominio, senha, 3, 0, out token))
            {
                CloseHandle(token);
                return 0;
            }
            return Marshal.GetLastWin32Error();
        }

        // ---------------- Conexões de rede (SMB) ----------------
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct NETRESOURCE
        {
            public int dwScope;
            public int dwType;
            public int dwDisplayType;
            public int dwUsage;
            public string lpLocalName;
            public string lpRemoteName;
            public string lpComment;
            public string lpProvider;
        }

        [DllImport("mpr.dll", EntryPoint = "WNetAddConnection2W", CharSet = CharSet.Unicode)]
        private static extern int WNetAddConnection2(ref NETRESOURCE recurso, string senha, string usuario, int flags);

        [DllImport("mpr.dll", EntryPoint = "WNetCancelConnection2W", CharSet = CharSet.Unicode)]
        private static extern int WNetCancelConnection2(string nome, int flags, bool forcar);

        // Conecta usando as credenciais padrão (Gerenciador de Credenciais
        // ou sessão atual). Nunca recebe senha.
        public static int Conectar(string remoto, string letra, bool persistente)
        {
            NETRESOURCE r = new NETRESOURCE();
            bool temLetra = !string.IsNullOrEmpty(letra);
            r.dwType = temLetra ? 1 : 0;           // RESOURCETYPE_DISK : RESOURCETYPE_ANY
            r.lpLocalName = temLetra ? letra : null;
            r.lpRemoteName = remoto;
            int flags = (temLetra && persistente) ? 1 : 0; // CONNECT_UPDATE_PROFILE
            return WNetAddConnection2(ref r, null, null, flags);
        }

        public static int Desconectar(string nome, bool forcar)
        {
            return WNetCancelConnection2(nome, 0, forcar);
        }

        // ---------------- Lixeira ----------------
        [StructLayout(LayoutKind.Sequential)]
        private struct SHQUERYRBINFO
        {
            public int cbSize;
            public long i64Size;
            public long i64NumItems;
        }

        [DllImport("shell32.dll", EntryPoint = "SHQueryRecycleBinW", CharSet = CharSet.Unicode)]
        private static extern int SHQueryRecycleBin(string raiz, ref SHQUERYRBINFO info);

        [DllImport("shell32.dll", EntryPoint = "SHEmptyRecycleBinW", CharSet = CharSet.Unicode)]
        private static extern int SHEmptyRecycleBin(IntPtr janela, string raiz, int flags);

        // Retorna a quantidade de itens da Lixeira do usuário atual
        // (todas as unidades) ou -1 se não foi possível consultar.
        public static long ItensLixeira(out long bytes)
        {
            SHQUERYRBINFO i = new SHQUERYRBINFO();
            i.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));
            bytes = 0;
            int hr = SHQueryRecycleBin(null, ref i);
            if (hr != 0) return -1;
            bytes = i.i64Size;
            return i.i64NumItems;
        }

        // Sem confirmação, sem barra de progresso, sem som (a confirmação
        // é feita pela própria aplicação). Retorna HRESULT.
        public static int EsvaziarLixeira()
        {
            return SHEmptyRecycleBin(IntPtr.Zero, null, 0x1 | 0x2 | 0x4);
        }

        // ---------------- Console ----------------
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr janela, int comando);

        public static void OcultarConsole()
        {
            IntPtr h = GetConsoleWindow();
            if (h != IntPtr.Zero) ShowWindow(h, 0);
        }
    }
}
'@
}
#endregion

#region Utilidades gerais ------------------------------------------------------

function Test-ValorPendente {
    <# Verdadeiro quando o valor está vazio ou marcado com TODO_VALIDAR. #>
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return $true }
    $texto = [string]$Valor
    return ([string]::IsNullOrWhiteSpace($texto) -or $texto -match [regex]::Escape($script:MarcadorPendente))
}

function Assert-ValorConfigurado {
    <# Interrompe a ação (sem expor detalhes ao usuário) se o valor ainda não foi configurado. #>
    param([AllowNull()][object]$Valor, [Parameter(Mandatory)][string]$Chave)
    if (Test-ValorPendente $Valor) {
        throw ('CONFIG_PENDENTE:{0}' -f $Chave)
    }
    return $Valor
}

function Get-MensagemInterna {
    <# Mensagem da exceção mais interna (detalhe técnico, só para log). #>
    param([Parameter(Mandatory)][System.Exception]$Excecao)
    $e = $Excecao
    while ($e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

function Get-CodigoErroExcecao {
    <# Procura um código Win32/HRESULT na cadeia de exceções. #>
    param([Parameter(Mandatory)][System.Exception]$Excecao)
    $e = $Excecao
    while ($e) {
        if ($e -is [System.ComponentModel.Win32Exception]) { return [string]$e.NativeErrorCode }
        if ($e.HResult -ne 0 -and $e.HResult -ne -2146233088 -and $e.HResult -ne -2146233079) {
            return ('0x{0:X8}' -f $e.HResult)
        }
        $e = $e.InnerException
    }
    return ''
}

function Protect-TextoSensivel {
    <#
        Última barreira antes de qualquer texto ir para log/área de
        transferência: mascara padrões que lembram senha ou token.
        A aplicação não passa senhas para cá; isto é defesa extra.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Texto)
    if ([string]::IsNullOrEmpty($Texto)) { return '' }
    $t = $Texto
    $t = [regex]::Replace($t, '(?i)(/pass(word)?\s*[:=]\s*)("[^"]*"|\S+)', '$1***')
    $t = [regex]::Replace($t, '(?i)\b(senha|password|passwd|pwd|token|secret|segredo)\b(\s*[:=]\s*)("[^"]*"|\S+)', '$1$2***')
    $t = [regex]::Replace($t, '(?i)(authorization\s*:\s*)(\S+\s+)?\S+', '$1***')
    if ($t.Length -gt 4000) { $t = $t.Substring(0, 4000) + ' [...]' }
    return $t
}

function Get-MensagemErro {
    <# Converte códigos Win32 em mensagens amigáveis em português. #>
    param([Parameter(Mandatory)][int]$Codigo)
    switch ($Codigo) {
        0     { return 'Operação concluída.' }
        2     { return 'Item não encontrado.' }
        5     { return 'Acesso negado (sem permissão).' }
        53    { return 'Servidor não encontrado na rede. Verifique a conexão ou a VPN.' }
        67    { return 'Nome de compartilhamento não encontrado.' }
        85    { return 'A letra de unidade já está em uso.' }
        86    { return 'Senha de rede incorreta.' }
        1168  { return 'Credencial não encontrada.' }
        1203  { return 'Caminho de rede não encontrado. Verifique a conexão ou a VPN.' }
        1219  { return 'Já existe uma conexão com este servidor usando outro usuário. Feche as pastas/unidades desse servidor ou faça logoff e tente de novo.' }
        1222  { return 'A rede não está disponível.' }
        1223  { return 'Operação cancelada pelo usuário.' }
        1311  { return 'Nenhum servidor do domínio respondeu. Verifique a rede ou a VPN.' }
        1312  { return 'O Windows não permitiu salvar a credencial (política de segurança ou sessão).' }
        1326  { return 'Usuário ou senha incorretos.' }
        1327  { return 'A conta tem restrições de logon.' }
        1328  { return 'Fora do horário permitido para esta conta.' }
        1329  { return 'Esta conta não pode ser usada neste computador.' }
        1330  { return 'A senha expirou. Troque a senha antes de continuar.' }
        1331  { return 'A conta está desabilitada.' }
        1355  { return 'Domínio não encontrado. Verifique a rede ou a VPN.' }
        1385  { return 'Senha correta, mas este tipo de logon não é permitido para a conta.' }
        1722  { return 'Servidor indisponível (RPC).' }
        1793  { return 'A conta expirou.' }
        1907  { return 'A senha precisa ser trocada antes do primeiro uso.' }
        1909  { return 'A conta está bloqueada. Procure a TI.' }
        2250  { return 'Não havia conexão para encerrar.' }
        default { return ('Erro do Windows {0}.' -f $Codigo) }
    }
}

function New-ResultadoAcao {
    <# Objeto padrão de resultado devolvido por todas as ações. #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Sucesso', 'Parcial', 'Falha', 'Aviso', 'Cancelado', 'Negado')]
        [string]$Status,
        [string]$Mensagem = '',
        [string]$Recomendacao = '',
        [object[]]$Itens = @(),
        [string]$Detalhes = '',
        [string]$CodigoErro = '',
        [string]$Elevacao = 'NaoNecessaria',
        [hashtable]$PosAcao = $null,
        [string]$Saida = '',
        [object]$Dados = $null
    )
    return [pscustomobject]@{
        Status       = $Status
        Mensagem     = $Mensagem
        Recomendacao = $Recomendacao
        Itens        = @($Itens | ForEach-Object { [string]$_ })
        Detalhes     = (Protect-TextoSensivel $Detalhes)
        CodigoErro   = $CodigoErro
        Elevacao     = $Elevacao
        PosAcao      = $PosAcao
        Saida        = $Saida
        Dados        = $Dados
    }
}

function Get-StatusFinal {
    <# Consolida contagens em Sucesso / Parcial / Falha / Aviso. #>
    param([int]$Sucessos = 0, [int]$Falhas = 0, [int]$Avisos = 0)
    if ($Falhas -gt 0 -and $Sucessos -gt 0) { return 'Parcial' }
    if ($Falhas -gt 0) { return 'Falha' }
    if ($Avisos -gt 0) { return 'Aviso' }
    return 'Sucesso'
}

function Get-CaminhoSistema {
    <#
        Pasta System32 "real". Se o PowerShell for 32 bits num Windows
        64 bits, System32 é redirecionado; Sysnative contorna isso
        (dsa.msc, mmc.exe e pnputil.exe só existem na versão 64 bits).
    #>
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        return (Join-Path $env:SystemRoot 'Sysnative')
    }
    return (Join-Path $env:SystemRoot 'System32')
}

function Get-CaminhoPowerShell {
    return (Join-Path (Get-CaminhoSistema) 'WindowsPowerShell\v1.0\powershell.exe')
}

#endregion

#region Validação de entradas --------------------------------------------------

function Test-NomeHost {
    <# Nome de servidor (NetBIOS ou FQDN). Sem espaços, barras ou aspas. #>
    param([AllowNull()][string]$Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return $false }
    if ($Nome.Length -gt 253) { return $false }
    # Só números e pontos não é nome: deve ser um IPv4 válido (ver Test-EnderecoIPv4)
    if ($Nome -match '^[\d\.]+$') { return $false }
    return ($Nome -match '^[A-Za-z0-9]([A-Za-z0-9\-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9\-]{0,62}))*$')
}

function Test-EnderecoIPv4 {
    param([AllowNull()][string]$Endereco)
    if ([string]::IsNullOrWhiteSpace($Endereco)) { return $false }
    if ($Endereco -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($i in 1..4) { if ([int]$Matches[$i] -gt 255) { return $false } }
    return $true
}

function Test-CaminhoUnc {
    <# \\servidor\compartilhamento[\subpasta...] — sem "..", sem caracteres proibidos. #>
    param([AllowNull()][string]$Caminho)
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return $false }
    if ($Caminho -match '\.\.') { return $false }
    if ($Caminho -notmatch '^\\\\([^\\/:*?"<>|\s]+)\\[^\\/:*?"<>|]+(\\[^\\/:*?"<>|]+)*\\?$') { return $false }
    $servidor = $Matches[1]
    return ((Test-NomeHost $servidor) -or (Test-EnderecoIPv4 $servidor))
}

function Get-ServidorDoCaminho {
    param([Parameter(Mandatory)][string]$Caminho)
    if ($Caminho -match '^\\\\([^\\]+)\\') { return $Matches[1] }
    return $null
}

function ConvertTo-UsuarioDominio {
    <#
        Normaliza o usuário digitado para DOMINIO\usuario.
        Aceita: usuario | DOMINIO\usuario | usuario@sufixo
        Remove espaços nas pontas e aspas envolventes.
        Recusa domínio diferente do configurado e caracteres proibidos
        no sAMAccountName. Nunca recebe a senha.
    #>
    param([AllowNull()][string]$Entrada, [Parameter(Mandatory)][hashtable]$Config)

    $falha = {
        param($m)
        [pscustomobject]@{ Valido = $false; Sam = ''; Dominio = ''; Completo = ''; Mensagem = $m }
    }

    $netbios = [string]$Config.Dominio.NetBIOS
    if (Test-ValorPendente $netbios) { return (& $falha 'O domínio ainda não foi configurado pela TI.') }

    $t = if ($null -eq $Entrada) { '' } else { $Entrada.Trim() }
    if ($t.Length -ge 2 -and (($t[0] -eq '"' -and $t[-1] -eq '"') -or ($t[0] -eq "'" -and $t[-1] -eq "'"))) {
        $t = $t.Substring(1, $t.Length - 2).Trim()
    }
    if (-not $t) { return (& $falha 'Informe o usuário.') }

    $sam = $t
    if ($t.Contains('\')) {
        $partes = $t.Split('\')
        if ($partes.Count -ne 2) { return (& $falha 'Formato de usuário inválido. Use apenas o usuário, por exemplo: joao.silva') }
        $dominioDigitado = $partes[0].Trim()
        $sam = $partes[1].Trim()
        $aceitos = @($netbios)
        if (-not (Test-ValorPendente $Config.Dominio.FQDN)) { $aceitos += [string]$Config.Dominio.FQDN }
        if ($aceitos -notcontains $dominioDigitado) {
            return (& $falha ('Use uma conta do domínio {0}.' -f $netbios))
        }
    }
    elseif ($t.Contains('@')) {
        $pos = $t.LastIndexOf('@')
        $sam = $t.Substring(0, $pos).Trim()
        $sufixo = $t.Substring($pos + 1).Trim()
        $sufixos = @(@($Config.Dominio.SufixosUPN) | Where-Object { -not (Test-ValorPendente $_) })
        if ($sufixos.Count -gt 0 -and ($sufixos -notcontains $sufixo)) {
            return (& $falha 'O e-mail/UPN informado não pertence ao domínio da empresa. Use apenas o usuário.')
        }
    }

    $max = 20
    if ($Config.Dominio.ContainsKey('TamanhoMaximoUsuario')) { $max = [int]$Config.Dominio.TamanhoMaximoUsuario }

    if (-not $sam) { return (& $falha 'Informe o usuário.') }
    if ($sam.Length -gt $max) { return (& $falha ('O usuário deve ter no máximo {0} caracteres.' -f $max)) }
    # Caracteres proibidos no sAMAccountName + caracteres de controle
    if ($sam -notmatch '^[^"/\\\[\]:;|=,+*?<>@\x00-\x1F]+$') {
        return (& $falha 'O usuário contém caracteres não permitidos.')
    }
    if ($sam.EndsWith('.') -or $sam -match '^[\s\.]+$') {
        return (& $falha 'Usuário inválido.')
    }

    return [pscustomobject]@{
        Valido   = $true
        Sam      = $sam
        Dominio  = $netbios
        Completo = ('{0}\{1}' -f $netbios, $sam)
        Mensagem = ''
    }
}

#endregion

#region Configuração -----------------------------------------------------------

function Test-SuporteConfig {
    <# Valida estrutura e formato. Valores TODO_VALIDAR são aceitos (bloqueiam só a função). #>
    param([Parameter(Mandatory)][hashtable]$Config)

    $erros = New-Object System.Collections.Generic.List[string]
    $secoes = 'Aplicacao', 'Visual', 'Dominio', 'Perfis', 'Credenciais', 'Cubo', 'ServidorAD',
              'ServidoresArquivos', 'Compartilhamentos', 'Impressoras', 'Limpeza', 'Rede', 'Logs', 'Recursos'
    foreach ($s in $secoes) {
        if (-not $Config.ContainsKey($s)) { $erros.Add(('Seção obrigatória ausente: {0}' -f $s)) }
    }
    if ($erros.Count -gt 0) { return $erros.ToArray() }

    foreach ($k in @($Config.Visual.Keys)) {
        if ($k -like 'Cor*') {
            $v = [string]$Config.Visual[$k]
            if ($v -notmatch '^#[0-9A-Fa-f]{6}$') { $erros.Add(('Visual.{0} deve estar no formato #RRGGBB (atual: "{1}").' -f $k, $v)) }
        }
    }

    $hosts = @(
        @{ Chave = 'Cubo.Servidor'; Valor = $Config.Cubo.Servidor },
        @{ Chave = 'ServidorAD.Servidor'; Valor = $Config.ServidorAD.Servidor }
    )
    $i = 0
    foreach ($s in @($Config.ServidoresArquivos)) { $hosts += @{ Chave = ('ServidoresArquivos[{0}]' -f $i); Valor = $s }; $i++ }
    foreach ($h in $hosts) {
        if (-not (Test-ValorPendente $h.Valor) -and -not (Test-NomeHost ([string]$h.Valor))) {
            $erros.Add(('{0}: nome de servidor inválido ("{1}").' -f $h.Chave, $h.Valor))
        }
    }

    if (@('CredencialSalva', 'OutroUsuario') -notcontains [string]$Config.ServidorAD.ModoAbertura) {
        $erros.Add('ServidorAD.ModoAbertura deve ser "CredencialSalva" ou "OutroUsuario".')
    }

    $ids = @{}
    foreach ($c in @($Config.Compartilhamentos)) {
        $id = [string]$c.Id
        if ($id -notmatch '^[A-Za-z0-9_]{1,40}$') { $erros.Add(('Compartilhamento com Id inválido: "{0}".' -f $id)); continue }
        if ($ids.ContainsKey($id)) { $erros.Add(('Id de compartilhamento repetido: {0}.' -f $id)) }
        $ids[$id] = $true
        if (-not (Test-ValorPendente $c.Caminho) -and -not (Test-CaminhoUnc ([string]$c.Caminho))) {
            $erros.Add(('Compartilhamento {0}: caminho UNC inválido.' -f $id))
        }
        if ($c.LetraUnidade -and ([string]$c.LetraUnidade -notmatch '^[D-Zd-z]:$')) {
            $erros.Add(('Compartilhamento {0}: LetraUnidade deve ser como "X:".' -f $id))
        }
        foreach ($p in @($c.Perfis)) {
            if ($script:PerfisValidos -notcontains $p) { $erros.Add(('Compartilhamento {0}: perfil inválido "{1}".' -f $id, $p)) }
        }
    }

    $ids = @{}
    foreach ($imp in @($Config.Impressoras)) {
        $id = [string]$imp.Id
        if ($id -notmatch '^[A-Za-z0-9_]{1,40}$') { $erros.Add(('Impressora com Id inválido: "{0}".' -f $id)); continue }
        if ($ids.ContainsKey($id)) { $erros.Add(('Id de impressora repetido: {0}.' -f $id)) }
        $ids[$id] = $true
        if (-not (Test-ValorPendente $imp.IP) -and -not (Test-EnderecoIPv4 ([string]$imp.IP)) -and -not (Test-NomeHost ([string]$imp.IP))) {
            $erros.Add(('Impressora {0}: IP/nome inválido.' -f $id))
        }
        if (@('RAW', 'LPR') -notcontains [string]$imp.Protocolo) { $erros.Add(('Impressora {0}: Protocolo deve ser RAW ou LPR.' -f $id)) }
        $porta = 0
        if (-not [int]::TryParse([string]$imp.Porta, [ref]$porta) -or $porta -lt 1 -or $porta -gt 65535) {
            $erros.Add(('Impressora {0}: Porta inválida.' -f $id))
        }
        if (-not (Test-ValorPendente $imp.NomePorta) -and ([string]$imp.NomePorta -notmatch '^[A-Za-z0-9_.\-]{1,64}$')) {
            $erros.Add(('Impressora {0}: NomePorta inválido.' -f $id))
        }
        if ([string]$imp.Nome -match '[\\,"]') { $erros.Add(('Impressora {0}: o nome não pode conter \ , ou aspas.' -f $id)) }
        if ($imp.DriverInf -and -not (Test-ValorPendente $imp.DriverInf) -and ([string]$imp.DriverInf -notmatch '\.inf$')) {
            $erros.Add(('Impressora {0}: DriverInf deve apontar para um arquivo .inf.' -f $id))
        }
    }

    foreach ($r in @($Config.Recursos.Keys)) {
        foreach ($p in @($Config.Recursos[$r].Perfis)) {
            if ($script:PerfisValidos -notcontains $p) { $erros.Add(('Recursos.{0}: perfil inválido "{1}".' -f $r, $p)) }
        }
    }

    $idade = 0
    if (-not [int]::TryParse([string]$Config.Limpeza.IdadeMinimaHoras, [ref]$idade) -or $idade -lt 0) {
        $erros.Add('Limpeza.IdadeMinimaHoras deve ser um número inteiro >= 0.')
    }
    $tm = 0
    if (-not [int]::TryParse([string]$Config.Rede.TimeoutMs, [ref]$tm) -or $tm -lt 500 -or $tm -gt 30000) {
        $erros.Add('Rede.TimeoutMs deve estar entre 500 e 30000.')
    }

    return $erros.ToArray()
}

function Import-SuporteConfig {
    param([Parameter(Mandatory)][string]$Caminho)
    if (-not (Test-Path -LiteralPath $Caminho -PathType Leaf)) {
        throw ('Arquivo de configuração não encontrado: {0}' -f $Caminho)
    }
    $config = Import-PowerShellDataFile -LiteralPath $Caminho
    $erros = @(Test-SuporteConfig -Config $config)
    if ($erros.Count -gt 0) {
        throw ("Configuração inválida:`n - " + ($erros -join "`n - "))
    }
    return $config
}

function Get-ValoresPendentes {
    <# Lista as chaves da configuração que ainda contêm TODO_VALIDAR. #>
    param([AllowNull()][object]$No, [string]$Caminho = '')
    $saida = New-Object System.Collections.Generic.List[string]
    if ($No -is [hashtable]) {
        foreach ($k in $No.Keys) {
            $sub = if ($Caminho) { '{0}.{1}' -f $Caminho, $k } else { [string]$k }
            foreach ($x in @(Get-ValoresPendentes -No $No[$k] -Caminho $sub)) { $saida.Add($x) }
        }
    }
    elseif ($No -is [array]) {
        for ($i = 0; $i -lt $No.Count; $i++) {
            foreach ($x in @(Get-ValoresPendentes -No $No[$i] -Caminho ('{0}[{1}]' -f $Caminho, $i))) { $saida.Add($x) }
        }
    }
    elseif ($No -is [string] -and $No -match [regex]::Escape($script:MarcadorPendente)) {
        $saida.Add($Caminho)
    }
    $ordenado = @($saida.ToArray() | Sort-Object)
    return $ordenado
}

#endregion

#region Contexto, progresso e log ----------------------------------------------

function Resolve-DiretorioLog {
    <# Usa a pasta configurada; se não for possível gravar, cai para %TEMP%. #>
    param([Parameter(Mandatory)][hashtable]$Config)
    $candidatos = @(
        [Environment]::ExpandEnvironmentVariables([string]$Config.Logs.Diretorio),
        (Join-Path ([IO.Path]::GetTempPath()) 'EVEN-SuporteTI\Logs')
    )
    foreach ($d in $candidatos) {
        if (Test-ValorPendente $d) { continue }
        try {
            if (-not (Test-Path -LiteralPath $d -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop)
            }
            $teste = Join-Path $d ('.teste_{0}.tmp' -f [guid]::NewGuid())
            [IO.File]::WriteAllText($teste, '')
            [IO.File]::Delete($teste)
            return $d
        }
        catch { continue }
    }
    return $null
}

function Initialize-SuporteContexto {
    <# Prepara o contexto usado por log, progresso e checagem de permissão. #>
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$AppRoot,
        [AllowNull()][object]$Fila
    )
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:Contexto = @{
        Config       = $Config
        AppRoot      = $AppRoot
        Fila         = $Fila
        Usuario      = $identidade.Name
        Computador   = $env:COMPUTERNAME
        Versao       = [string]$Config.Aplicacao.Versao
        DiretorioLog = (Resolve-DiretorioLog -Config $Config)
        Perfil       = 'Usuario'
        MotivoPerfil = ''
    }
    $perfil = Get-PerfilUsuario -Config $Config
    $script:Contexto.Perfil = $perfil.Perfil
    $script:Contexto.MotivoPerfil = $perfil.Motivo
    return $script:Contexto
}

function Get-SuporteContexto {
    if (-not $script:Contexto) { throw 'Contexto da aplicação não inicializado.' }
    return $script:Contexto
}

function Send-Progresso {
    <# Envia progresso/atividade para a interface (fila thread-safe). #>
    param(
        [Parameter(Mandatory)][string]$Texto,
        [int]$Percentual = -1,
        [ValidateSet('Progresso', 'Atividade')][string]$Tipo = 'Progresso'
    )
    $ctx = $script:Contexto
    if ($ctx -and $ctx.Fila) {
        $ctx.Fila.Enqueue([pscustomobject]@{
            Tipo       = $Tipo
            Texto      = (Protect-TextoSensivel $Texto)
            Percentual = $Percentual
            Hora       = Get-Date
        })
    }
}

function Write-SuporteLog {
    <#
        Grava uma linha JSON por evento em SuporteTI_aaaaMMdd.log.
        Campos: data/hora, versão, usuário, computador, perfil, função,
        resultado, elevação, código de erro e mensagem técnica.
        NUNCA recebe senha; a mensagem passa por Protect-TextoSensivel.
    #>
    param(
        [Parameter(Mandatory)][string]$Funcao,
        [Parameter(Mandatory)]
        [ValidateSet('Inicio', 'Sucesso', 'Parcial', 'Falha', 'Aviso', 'Cancelado', 'Negado', 'Info')]
        [string]$Resultado,
        [string]$Mensagem = '',
        [string]$Elevacao = 'NaoNecessaria',
        [string]$CodigoErro = ''
    )
    $ctx = $script:Contexto
    if (-not $ctx -or -not $ctx.DiretorioLog) { return }

    $registro = [ordered]@{
        DataHora   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        Versao     = $ctx.Versao
        Usuario    = $ctx.Usuario
        Computador = $ctx.Computador
        Perfil     = $ctx.Perfil
        Funcao     = $Funcao
        Resultado  = $Resultado
        Elevacao   = $Elevacao
        CodigoErro = $CodigoErro
        Mensagem   = (Protect-TextoSensivel $Mensagem)
    }
    $linha = ConvertTo-Json -InputObject $registro -Compress
    $arquivo = Join-Path $ctx.DiretorioLog ('SuporteTI_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

    $mutex = $null
    $obtido = $false
    try {
        # Mutex evita linhas misturadas quando a interface e a tarefa em
        # segundo plano gravam ao mesmo tempo.
        $mutex = New-Object System.Threading.Mutex($false, 'Local\EVEN_SuporteTI_Log')
        try { $obtido = $mutex.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $obtido = $true }
        [IO.File]::AppendAllText($arquivo, $linha + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        # Falha de log não pode derrubar a ação, mas não é silenciosa:
        Send-Progresso -Tipo Atividade -Texto 'Aviso: não foi possível gravar o log desta ação.'
    }
    finally {
        if ($mutex) {
            if ($obtido) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
    }
}

function Remove-LogsAntigos {
    <# Apaga somente arquivos SuporteTI_*.log mais antigos que a retenção. #>
    $ctx = Get-SuporteContexto
    if (-not $ctx.DiretorioLog) { return }
    $dias = 30
    [void][int]::TryParse([string]$ctx.Config.Logs.RetencaoDias, [ref]$dias)
    $limite = (Get-Date).AddDays(-1 * [Math]::Max($dias, 1))
    Get-ChildItem -LiteralPath $ctx.DiretorioLog -Filter 'SuporteTI_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limite } |
        ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }
            catch { Write-SuporteLog -Funcao 'Logs' -Resultado Aviso -Mensagem ('Não foi possível remover log antigo: {0}' -f $_.Exception.Message) }
        }
}

#endregion

#region Perfis e permissões ----------------------------------------------------

function Test-Administrador {
    <# Verdadeiro somente se o processo atual estiver ELEVADO. #>
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PastaProtegida {
    <# A aplicação está numa pasta onde só administradores gravam? #>
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][hashtable]$Config)
    $alvo = [IO.Path]::GetFullPath($Pasta).TrimEnd('\') + '\'
    $confiaveis = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) { if ($p) { $confiaveis.Add($p) } }
    foreach ($p in @($Config.Aplicacao.PastasConfiaveis)) { if ($p -and -not (Test-ValorPendente $p)) { $confiaveis.Add([string]$p) } }
    foreach ($c in $confiaveis) {
        $base = [IO.Path]::GetFullPath($c).TrimEnd('\') + '\'
        if ($alvo.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Resolve-SidGrupo {
    <# SID configurado; se só houver nome, tenta traduzir (pode falhar fora da rede). #>
    param([AllowNull()][hashtable]$Grupo)
    if (-not $Grupo) { return $null }
    $sid = [string]$Grupo['SID']
    if (-not (Test-ValorPendente $sid)) {
        try { return (New-Object Security.Principal.SecurityIdentifier($sid)).Value } catch { return $null }
    }
    $nome = [string]$Grupo['Nome']
    if (-not (Test-ValorPendente $nome)) {
        try {
            return (New-Object Security.Principal.NTAccount($nome)).Translate([Security.Principal.SecurityIdentifier]).Value
        }
        catch { return $null }
    }
    return $null
}

function Get-PerfilUsuario {
    <#
        Identifica o perfil pelos grupos do TOKEN DE LOGON (não consulta o
        AD em tempo real, então funciona fora da rede). Se o grupo não
        estiver configurado ou não puder ser resolvido, o resultado é
        "Usuario" (falha segura). Mudanças de grupo valem após novo logon.
    #>
    param([Parameter(Mandatory)][hashtable]$Config)
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($g in $identidade.Groups) { [void]$sids.Add($g.Value) }

    $p = $Config.Perfis
    $sidAdm = Resolve-SidGrupo $p.GrupoAdministradores
    $sidTec = Resolve-SidGrupo $p.GrupoTecnicos

    if ($sidAdm -and $sids.Contains($sidAdm)) {
        return [pscustomobject]@{ Perfil = 'Administrador'; Motivo = 'Membro do grupo de administradores configurado.' }
    }
    if ($sidTec -and $sids.Contains($sidTec)) {
        return [pscustomobject]@{ Perfil = 'Tecnico'; Motivo = 'Membro do grupo de técnicos configurado.' }
    }
    if ($p.ConsiderarAdminLocalElevadoComoTecnico -and (Test-Administrador)) {
        return [pscustomobject]@{ Perfil = 'Tecnico'; Motivo = 'Administrador local elevado (opção de homologação ativa).' }
    }
    $motivo = 'Perfil padrão.'
    if (-not $sidAdm -and -not $sidTec) { $motivo = 'Grupos de TI não configurados ou não resolvidos (falha segura).' }
    return [pscustomobject]@{ Perfil = 'Usuario'; Motivo = $motivo }
}

function Test-PermissaoRecurso {
    param([Parameter(Mandatory)][string]$Id, [string]$Perfil = '')
    $ctx = Get-SuporteContexto
    if (-not $Perfil) { $Perfil = $ctx.Perfil }
    $recursos = $ctx.Config.Recursos
    if (-not $recursos.ContainsKey($Id)) { return $false }
    $r = $recursos[$Id]
    if (-not $r.Habilitado) { return $false }
    return (@($r.Perfis) -contains $Perfil)
}

function Assert-PermissaoRecurso {
    <# Recalcula o perfil NA HORA da execução (não confia só na interface). #>
    param([Parameter(Mandatory)][string]$Id)
    $ctx = Get-SuporteContexto
    $perfil = (Get-PerfilUsuario -Config $ctx.Config).Perfil
    $ctx.Perfil = $perfil
    if (-not (Test-PermissaoRecurso -Id $Id -Perfil $perfil)) {
        throw ('ACESSO_NEGADO:{0}' -f $Id)
    }
}

#endregion

#region Rede com timeout -------------------------------------------------------

function Resolve-NomeHost {
    param([Parameter(Mandatory)][string]$Nome, [int]$TimeoutMs = 3000)
    try {
        $tarefa = [System.Net.Dns]::GetHostAddressesAsync($Nome)
        if (-not $tarefa.Wait($TimeoutMs)) {
            return [pscustomobject]@{ Ok = $false; Enderecos = @(); Motivo = 'DNS não respondeu a tempo (timeout).' }
        }
        $lista = @($tarefa.Result)
        if ($lista.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Enderecos = @(); Motivo = 'Nome não encontrado no DNS.' } }
        return [pscustomobject]@{ Ok = $true; Enderecos = $lista; Motivo = '' }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Enderecos = @(); Motivo = ('Nome não encontrado no DNS ({0}).' -f (Get-MensagemInterna $_.Exception)) }
    }
}

function Test-PortaTcp {
    <# Teste de conexão TCP com timeout real (Test-NetConnection não tem timeout). #>
    param(
        [Parameter(Mandatory)][string]$Destino,
        [Parameter(Mandatory)][int]$Porta,
        [int]$TimeoutMs = 0
    )
    if ($TimeoutMs -le 0) {
        $TimeoutMs = 3000
        if ($script:Contexto) { [void][int]::TryParse([string]$script:Contexto.Config.Rede.TimeoutMs, [ref]$TimeoutMs) }
    }
    $res = [pscustomobject]@{ Destino = $Destino; Porta = $Porta; Ok = $false; Motivo = ''; Ms = 0 }
    $cronometro = [Diagnostics.Stopwatch]::StartNew()

    if (Test-EnderecoIPv4 $Destino) {
        $ip = [System.Net.IPAddress]::Parse($Destino)
    }
    else {
        $dns = Resolve-NomeHost -Nome $Destino -TimeoutMs $TimeoutMs
        if (-not $dns.Ok) { $res.Motivo = $dns.Motivo; $res.Ms = $cronometro.ElapsedMilliseconds; return $res }
        $ip = @($dns.Enderecos | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1)
        if ($ip.Count -eq 0) { $ip = @($dns.Enderecos | Select-Object -First 1) }
        $ip = $ip[0]
    }

    $cliente = New-Object System.Net.Sockets.TcpClient($ip.AddressFamily)
    try {
        $tarefa = $cliente.ConnectAsync($ip, $Porta)
        if ($tarefa.Wait($TimeoutMs)) {
            $res.Ok = $cliente.Connected
            if (-not $res.Ok) { $res.Motivo = 'Conexão recusada.' }
        }
        else {
            $res.Motivo = ('Sem resposta em {0} ms (timeout).' -f $TimeoutMs)
        }
    }
    catch {
        $res.Motivo = ('Conexão recusada ou rede inacessível ({0}).' -f (Get-MensagemInterna $_.Exception))
    }
    finally {
        $cliente.Close()
        $res.Ms = $cronometro.ElapsedMilliseconds
    }
    return $res
}

function Invoke-ComTimeout {
    <#
        Executa um bloco num runspace separado e desiste após o timeout.
        Usado para operações de arquivo em rede que podem travar
        (ex.: verificar se uma pasta UNC existe).
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$Argumentos = @(),
        [int]$TimeoutMs = 5000
    )
    $ps = [powershell]::Create()
    $concluido = $false
    try {
        [void]$ps.AddScript($Script.ToString())
        foreach ($a in $Argumentos) { [void]$ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        if ($handle.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $saida = $ps.EndInvoke($handle)
            $concluido = $true
            return [pscustomobject]@{ Concluido = $true; Saida = @($saida) }
        }
        [void]$ps.BeginStop($null, $null)
        return [pscustomobject]@{ Concluido = $false; Saida = @() }
    }
    finally {
        # Se travou, não chamamos Dispose (bloquearia); o runspace é
        # encerrado em segundo plano pelo BeginStop.
        if ($concluido) { $ps.Dispose() }
    }
}

function Test-CaminhoRede {
    <# Verifica se uma pasta de rede está acessível, com timeout. #>
    param([Parameter(Mandatory)][string]$Caminho, [int]$TimeoutMs = 8000)
    $r = Invoke-ComTimeout -Script { param($p) [System.IO.Directory]::Exists($p) } -Argumentos @($Caminho) -TimeoutMs $TimeoutMs
    if (-not $r.Concluido) { return [pscustomobject]@{ Concluido = $false; Existe = $false } }
    return [pscustomobject]@{ Concluido = $true; Existe = [bool]($r.Saida | Select-Object -First 1) }
}

#endregion

Export-ModuleMember -Function *
