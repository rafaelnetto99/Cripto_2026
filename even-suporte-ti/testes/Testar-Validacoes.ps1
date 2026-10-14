#Requires -Version 5.1
<#
    Arquivo : testes\Testar-Validacoes.ps1
    Projeto : Central de Suporte TI - EVEN (material para HOMOLOGAÇÃO)

    Testes automáticos das regras que NÃO tocam rede, credenciais nem
    impressoras: validação da configuração, normalização de usuário,
    mascaramento de senha no log, validação de nomes/IPs/caminhos.
    Seguro para rodar em qualquer máquina (não altera nada).

    Uso:  powershell.exe -NoProfile -File .\testes\Testar-Validacoes.ps1
    Saída: lista de testes com OK/FALHOU e código de saída 0 (tudo ok) ou 1.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
Import-Module -Name (Join-Path $raiz 'modules\SuporteTI.Core.psm1') -Force -DisableNameChecking

$script:falhas = 0
function Confirmar {
    param([string]$Nome, [bool]$Condicao)
    if ($Condicao) { Write-Host ('[OK]      {0}' -f $Nome) }
    else { Write-Host ('[FALHOU]  {0}' -f $Nome) -ForegroundColor Red; $script:falhas++ }
}

$config = Import-SuporteConfig -Caminho (Join-Path $raiz 'config\SuporteTI.config.psd1')
Confirmar 'Configuração carrega e é válida' ($null -ne $config)

# --- Usuário ---------------------------------------------------------------
$u = ConvertTo-UsuarioDominio -Entrada '  joao.silva  ' -Config $config
Confirmar 'Usuário simples com espaços nas pontas' ($u.Valido -and $u.Completo -eq ('{0}\joao.silva' -f $config.Dominio.NetBIOS))
$u = ConvertTo-UsuarioDominio -Entrada ('{0}\maria' -f $config.Dominio.NetBIOS.ToLower()) -Config $config
Confirmar 'DOMINIO\usuario (domínio em minúsculas)' ($u.Valido -and $u.Sam -eq 'maria')
$u = ConvertTo-UsuarioDominio -Entrada 'OUTRODOMINIO\maria' -Config $config
Confirmar 'Recusa domínio diferente' (-not $u.Valido)
$u = ConvertTo-UsuarioDominio -Entrada 'ana@empresa.com.br' -Config $config
Confirmar 'UPN com sufixo pendente é aceito (prefixo usado)' ($u.Valido -and $u.Sam -eq 'ana')
$u = ConvertTo-UsuarioDominio -Entrada '"pedro"' -Config $config
Confirmar 'Remove aspas envolventes' ($u.Valido -and $u.Sam -eq 'pedro')
foreach ($ruim in @('', '   ', 'a&calc', 'a|b', 'x"y', 'a*b', 'ab.', 'abcdefghijklmnopqrstuvwxyz', 'A\B\C', 'a<b>', 'usu;rio')) {
    $u = ConvertTo-UsuarioDominio -Entrada $ruim -Config $config
    $esperado = ($ruim -eq 'a&calc')   # & é permitido no sAMAccountName; não há cmd.exe para interpretar
    Confirmar ('Usuário "{0}" -> válido={1}' -f $ruim, $esperado) ($u.Valido -eq $esperado)
}

# --- Nomes, IPs, caminhos --------------------------------------------------
Confirmar 'Host NetBIOS válido' (Test-NomeHost 'SSPAD005')
Confirmar 'Host FQDN válido' (Test-NomeHost 'srv01.corp.exemplo.com')
Confirmar 'Host com espaço inválido' (-not (Test-NomeHost 'srv 01'))
Confirmar 'Host com & inválido' (-not (Test-NomeHost 'srv&calc'))
Confirmar 'IPv4 válido' (Test-EnderecoIPv4 '192.168.7.34')
Confirmar 'IPv4 inválido (256)' (-not (Test-EnderecoIPv4 '192.168.7.256'))
Confirmar 'IPv4 inválido (texto)' (-not (Test-EnderecoIPv4 '192.168.7.1; calc'))
Confirmar 'UNC válido com acento e espaço' (Test-CaminhoUnc '\\srv01\Arquivos\Jurídico\PASTA X\IMOBILIÁRIA')
Confirmar 'UNC com .. inválido' (-not (Test-CaminhoUnc '\\srv01\share\..\..\x'))
Confirmar 'Caminho local não é UNC' (-not (Test-CaminhoUnc 'C:\Windows'))
Confirmar 'UNC sem compartilhamento inválido' (-not (Test-CaminhoUnc '\\srv01'))

# --- Log nunca grava senha -------------------------------------------------
$t = Protect-TextoSensivel 'cmdkey /add:SRV /user:EVENSP\x /pass:Segredo@123'
Confirmar 'Mascara /pass:' ($t -notmatch 'Segredo@123')
$t = Protect-TextoSensivel 'senha=abc123 token: xyz'
Confirmar 'Mascara senha= e token:' ($t -notmatch 'abc123' -and $t -notmatch 'xyz')
$t = Protect-TextoSensivel ('a' * 5000)
Confirmar 'Trunca textos muito longos' ($t.Length -lt 4100)

# --- Configuração ----------------------------------------------------------
$pendentes = @(Get-ValoresPendentes -No $config)
Confirmar 'Lista valores TODO_VALIDAR' ($pendentes.Count -gt 0 -and ($pendentes -contains 'Dominio.FQDN'))
Confirmar 'Valor pendente detectado' (Test-ValorPendente 'TODO_VALIDAR')
Confirmar 'Valor vazio é pendente' (Test-ValorPendente '')
Confirmar 'Valor real não é pendente' (-not (Test-ValorPendente 'SSPDW01'))

$ruim = Import-PowerShellDataFile -Path (Join-Path $raiz 'config\SuporteTI.config.psd1')
$ruim.Visual.CorPrimaria = 'verde'
$ruim.Impressoras[0].IP = '999.1.1.1'
$ruim.Compartilhamentos[0].Caminho = 'C:\Windows'
$ruim.Recursos.AbrirAD.Perfis = @('Chefe')
$erros = @(Test-SuporteConfig -Config $ruim)
Confirmar 'Detecta cor, IP, caminho e perfil inválidos' ($erros.Count -ge 4)

Confirmar 'Status: sucesso' ((Get-StatusFinal -Sucessos 3) -eq 'Sucesso')
Confirmar 'Status: parcial' ((Get-StatusFinal -Sucessos 2 -Falhas 1) -eq 'Parcial')
Confirmar 'Status: falha' ((Get-StatusFinal -Falhas 2) -eq 'Falha')
Confirmar 'Status: aviso' ((Get-StatusFinal -Sucessos 1 -Avisos 1) -eq 'Aviso')

$r = New-ResultadoAcao -Status Falha -Mensagem 'x' -Detalhes 'password=SuperSecreta'
Confirmar 'Resultado mascara detalhes' ($r.Detalhes -notmatch 'SuperSecreta')

Write-Host ''
if ($script:falhas -gt 0) { Write-Host ('{0} teste(s) falharam.' -f $script:falhas) -ForegroundColor Red; exit 1 }
Write-Host 'Todos os testes passaram.' -ForegroundColor Green
exit 0
