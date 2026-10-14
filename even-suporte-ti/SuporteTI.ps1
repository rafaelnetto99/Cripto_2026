#Requires -Version 5.1
<#
.SYNOPSIS
    Central de Suporte TI - EVEN — aplicação principal (interface WPF).

.DESCRIPTION
    Arquivo: SuporteTI.ps1 (material para HOMOLOGAÇÃO, não para produção direta)

    Estrutura:
      SuporteTI.ps1            -> interface (este arquivo)
      SuporteTI.Elevado.ps1    -> tarefas administrativas pontuais (UAC)
      ui\MainWindow.xaml       -> layout
      config\*.psd1            -> configuração centralizada (sem código)
      modules\*.psm1           -> regras, validações, log, permissões

    A interface roda SEM privilégios. Operações demoradas rodam em um
    runspace separado (a janela não congela) e só uma operação por vez.
    Os módulos são carregados também no runspace, que confere de novo a
    permissão antes de executar.

.NOTES
    Inicie com:  powershell.exe -NoProfile -STA -File "SuporteTI.ps1"
    (ou pelo atalho / Iniciar-SuporteTI.bat). Não usa ExecutionPolicy Bypass.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppRoot   = $PSScriptRoot
$script:Modulos   = @('Core', 'Credenciais', 'Rede', 'Limpeza', 'Impressoras', 'ActiveDirectory', 'Acoes')
$script:Operacao  = $null
$script:AcaoAtual = $null
$script:UltimoResultado = $null
$script:UltimaAcaoExecutada = ''
$script:MutexInstancia = $null
$script:Fila = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

#region Catálogo de funções ----------------------------------------------------
# Textos e ícones das funções. Quem pode usar cada uma é definido em
# config\SuporteTI.config.psd1 (seção Recursos), não aqui.

$script:Grupos = @(
    [pscustomobject]@{ Id = 'Acesso';  Titulo = 'Acesso e credenciais';   Descricao = 'Atualize senhas salvas e acesse as pastas da empresa.' }
    [pscustomobject]@{ Id = 'Usuario'; Titulo = 'Ferramentas do usuário'; Descricao = 'Limpeza, impressoras e pastas autorizadas.' }
    [pscustomobject]@{ Id = 'TI';      Titulo = 'Ferramentas do TI';      Descricao = 'Funções exclusivas da equipe de TI.' }
)

$script:Catalogo = @(
    [pscustomobject]@{
        Id = 'CredencialCubo'; Grupo = 'Acesso'; Icone = 0xE8D7
        Titulo = 'Atualizar credencial do Cubo'
        Descricao = 'Salva com segurança seu usuário e senha de rede para acessar o Cubo. Use depois de trocar a senha.'
        Campos = 'Credencial'; RotuloUsuario = 'Usuário de rede'; Botao = 'Salvar credencial'
        Admin = 'Não exige administrador'
        Confirmacao = 'A credencial salva para o Cubo será substituída pela nova. Deseja continuar?'
        Secundaria = $null
    }
    [pscustomobject]@{
        Id = 'MapearPastas'; Grupo = 'Acesso'; Icone = 0xE8B7
        Titulo = 'Mapear pastas'
        Descricao = 'Atualiza sua credencial nos servidores de arquivos, confere o acesso e abre as pastas da empresa.'
        Campos = 'Credencial'; RotuloUsuario = 'Usuário de rede'; Botao = 'Atualizar e abrir pastas'
        Admin = 'Não exige administrador'
        Confirmacao = 'A credencial salva para os servidores de arquivos será substituída. Pastas abertas desses servidores podem ser desconectadas. Deseja continuar?'
        Secundaria = $null
    }
    [pscustomobject]@{
        Id = 'CredencialAD'; Grupo = 'Acesso'; Icone = 0xE72E
        Titulo = 'Configurar credencial administrativa do AD'
        Descricao = 'Salva a conta de suporte usada para administrar o Active Directory neste computador.'
        Campos = 'Credencial'; RotuloUsuario = 'Usuário de suporte'; Botao = 'Salvar credencial do AD'
        Admin = 'Não exige administrador local (exige conta de suporte do domínio)'
        Confirmacao = 'A credencial administrativa do AD salva neste usuário do Windows será substituída. Deseja continuar?'
        Secundaria = $null
    }
    [pscustomobject]@{
        Id = 'LimpezaTemporarios'; Grupo = 'Usuario'; Icone = 0xE74D
        Titulo = 'Limpar arquivos temporários'
        Descricao = 'Remove arquivos temporários antigos e esvazia a Lixeira. Arquivos em uso são preservados.'
        Campos = 'Opcoes'; Botao = 'Limpar agora'
        Admin = 'Temporários do Windows exigem administrador (o Windows pedirá autorização)'
        Confirmacao = ''
        Secundaria = $null
    }
    [pscustomobject]@{
        Id = 'Impressoras'; Grupo = 'Usuario'; Icone = 0xE749
        Titulo = 'Mapear impressoras'
        Descricao = 'Instala as impressoras da empresa. Uma falha não impede a instalação das demais.'
        Campos = 'Opcoes'; Botao = 'Instalar selecionadas'
        Admin = 'Exige administrador para instalar (o Windows pedirá autorização)'
        Confirmacao = ''
        Secundaria = $null
    }
    [pscustomobject]@{
        Id = 'AbrirPastas'; Grupo = 'Usuario'; Icone = 0xE838
        Titulo = 'Abrir pastas autorizadas'
        Descricao = 'Abre as pastas de rede liberadas para você, conferindo antes se o servidor responde.'
        Campos = 'Opcoes'; Botao = 'Abrir selecionadas'
        Admin = 'Não exige administrador'
        Confirmacao = ''
        Secundaria = $null
    }
    [pscustomobject]@{
        Id = 'AbrirAD'; Grupo = 'TI'; Icone = 0xE716
        Titulo = 'Abrir Active Directory'
        Descricao = 'Abre o console "Usuários e Computadores do Active Directory" conectado ao servidor configurado.'
        Campos = 'CredencialAD'; RotuloUsuario = 'Usuário de suporte'; Botao = 'Abrir Active Directory'
        Admin = 'Exige conta de suporte do domínio'
        Confirmacao = ''
        Secundaria = [pscustomobject]@{ Texto = 'Instalar RSAT (administrador)'; Tipo = 'Acao'; Alvo = 'InstalarRSAT' }
    }
    [pscustomobject]@{
        Id = 'Diagnostico'; Grupo = 'TI'; Icone = 0xE9D9
        Titulo = 'Diagnósticos administrativos'
        Descricao = 'Verifica ambiente, credenciais salvas (só existência), conectividade e pendências de configuração.'
        Campos = ''; Botao = 'Executar diagnóstico'
        Admin = 'Não exige administrador'
        Confirmacao = ''
        Secundaria = $null
    }
    [pscustomobject]@{
        Id = 'VerLogs'; Grupo = 'TI'; Icone = 0xE8A5
        Titulo = 'Visualizar logs técnicos'
        Descricao = 'Mostra os registros mais recentes desta ferramenta neste computador (sem senhas).'
        Campos = ''; Botao = 'Carregar logs'
        Admin = 'Não exige administrador'
        Confirmacao = ''
        Secundaria = [pscustomobject]@{ Texto = 'Abrir pasta de logs'; Tipo = 'Local'; Alvo = 'AbrirPastaLogs' }
    }
)

#endregion

#region Funções de interface ---------------------------------------------------

function Show-ErroFatal {
    param([string]$Mensagem)
    [void][System.Windows.MessageBox]::Show($Mensagem, 'Central de Suporte TI - EVEN', 'OK', 'Error')
}

function Get-AcaoCatalogo {
    param([string]$Id)
    return ($script:Catalogo | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function New-TextBlock {
    param([string]$Texto, [double]$Tamanho = 14, [string]$Peso = 'Normal', [switch]$Icone, [string]$CorRecurso = '', [string]$Margem = '0')
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Texto
    $tb.FontSize = $Tamanho
    $tb.FontWeight = $Peso
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = $Margem
    if ($Icone) { $tb.FontFamily = $script:Janela.FindResource('FonteIcones') }
    if ($CorRecurso) { $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $CorRecurso) }
    return $tb
}

function Add-Atividade {
    <# Linha amigável no painel "Atividades desta sessão". #>
    param([string]$Texto)
    $linha = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Texto
    [void]$script:UI.ListaAtividades.Items.Insert(0, $linha)
    while ($script:UI.ListaAtividades.Items.Count -gt 200) { $script:UI.ListaAtividades.Items.RemoveAt(200) }
}

function Set-Status {
    param([string]$Texto, [ValidateSet('Pronto', 'Processando', 'Sucesso', 'Aviso', 'Erro')][string]$Tipo = 'Pronto')
    $mapa = @{
        Pronto      = @{ Icone = 0xE73E; Cor = 'BrushSucesso'; Rodape = '● Pronto' }
        Processando = @{ Icone = 0xE895; Cor = 'BrushPrimaria'; Rodape = '● Em execução' }
        Sucesso     = @{ Icone = 0xE73E; Cor = 'BrushSucesso'; Rodape = '● Concluído' }
        Aviso       = @{ Icone = 0xE7BA; Cor = 'BrushAviso'; Rodape = '● Concluído com avisos' }
        Erro        = @{ Icone = 0xE783; Cor = 'BrushErro'; Rodape = '● Falha' }
    }
    $m = $mapa[$Tipo]
    $script:UI.TxtStatusIcone.Text = [string][char]$m.Icone
    $script:UI.TxtStatusIcone.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $m.Cor)
    $script:UI.TxtStatus.Text = $Texto
    $script:UI.TxtEstado.Text = $m.Rodape
}

function Set-NavSelecionado {
    param([string]$Nome)
    foreach ($n in 'BtnNavInicio', 'BtnNavAcesso', 'BtnNavUsuario', 'BtnNavTI') {
        $b = $script:UI[$n]
        if ($n -eq $Nome) {
            $b.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'BrushPrimaria')
            $b.FontWeight = 'SemiBold'
        }
        else {
            $b.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            $b.FontWeight = 'Normal'
        }
    }
}

function Get-AcoesVisiveis {
    param([string]$Grupo)
    return @($script:Catalogo | Where-Object { $_.Grupo -eq $Grupo -and (Test-PermissaoRecurso -Id $_.Id) })
}

function New-CartaoAcao {
    param([object]$Acao)
    $botao = New-Object System.Windows.Controls.Button
    $botao.Style = $script:Janela.FindResource('BotaoCartao')
    $botao.Tag = $Acao.Id
    [System.Windows.Automation.AutomationProperties]::SetName($botao, $Acao.Titulo)
    $botao.ToolTip = $Acao.Descricao

    $painel = New-Object System.Windows.Controls.StackPanel
    [void]$painel.Children.Add((New-TextBlock -Texto ([string][char]$Acao.Icone) -Tamanho 30 -Icone -CorRecurso 'BrushPrimaria' -Margem '0,0,0,10'))
    [void]$painel.Children.Add((New-TextBlock -Texto $Acao.Titulo -Tamanho 16 -Peso 'SemiBold'))
    [void]$painel.Children.Add((New-TextBlock -Texto $Acao.Descricao -Tamanho 13 -CorRecurso 'BrushTextoSecundario' -Margem '0,6,0,0'))
    if ($Acao.Admin -like 'Exige*' -or $Acao.Admin -like 'Temporários*') {
        $selo = New-Object System.Windows.Controls.StackPanel
        $selo.Orientation = 'Horizontal'
        $selo.Margin = '0,10,0,0'
        [void]$selo.Children.Add((New-TextBlock -Texto ([string][char]0xE7EF) -Tamanho 12 -Icone -Margem '0,1,6,0'))
        [void]$selo.Children.Add((New-TextBlock -Texto 'Pode exigir permissão especial' -Tamanho 12 -Peso 'SemiBold'))
        [void]$painel.Children.Add($selo)
    }
    $botao.Content = $painel
    $botao.Add_Click({ param($origem, $evento) Show-PainelAcao -Id ([string]$origem.Tag) })
    return $botao
}

function Show-Menu {
    param([ValidateSet('Todos', 'Acesso', 'Usuario', 'TI')][string]$Grupo = 'Todos')
    if ($script:Operacao) { return }
    $script:AcaoAtual = $null
    $script:UI.BtnExecutar.IsDefault = $false
    $script:UI.PwdSenha.Clear()
    $script:UI.PainelAcao.Visibility = 'Collapsed'
    $script:UI.PainelMenu.Visibility = 'Visible'

    $nav = @{ Todos = 'BtnNavInicio'; Acesso = 'BtnNavAcesso'; Usuario = 'BtnNavUsuario'; TI = 'BtnNavTI' }
    Set-NavSelecionado -Nome $nav[$Grupo]

    if ($Grupo -eq 'Todos') {
        $script:UI.TxtSecaoTitulo.Text = 'Início'
        $script:UI.TxtSecaoDescricao.Text = 'Escolha uma função. Cada cartão explica o que faz e se exige permissão especial.'
        $grupos = $script:Grupos
    }
    else {
        $g = $script:Grupos | Where-Object { $_.Id -eq $Grupo }
        $script:UI.TxtSecaoTitulo.Text = $g.Titulo
        $script:UI.TxtSecaoDescricao.Text = $g.Descricao
        $grupos = @($g)
    }

    $script:UI.PainelCartoes.Children.Clear()
    $total = 0
    foreach ($g in $grupos) {
        $acoes = @(Get-AcoesVisiveis -Grupo $g.Id)
        if ($acoes.Count -eq 0) { continue }
        if ($Grupo -eq 'Todos') {
            [void]$script:UI.PainelCartoes.Children.Add((New-TextBlock -Texto $g.Titulo -Tamanho 17 -Peso 'Bold' -Margem '0,6,0,10'))
        }
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($a in $acoes) { [void]$wrap.Children.Add((New-CartaoAcao -Acao $a)); $total++ }
        [void]$script:UI.PainelCartoes.Children.Add($wrap)
    }
    if ($total -eq 0) {
        [void]$script:UI.PainelCartoes.Children.Add((New-TextBlock -Texto 'Nenhuma função disponível para o seu perfil nesta seção.' -CorRecurso 'BrushTextoSecundario'))
    }
}

function Get-OpcoesAcao {
    <# Itens selecionáveis de cada função. IPs só aparecem para a TI. #>
    param([string]$Id)
    $cfg = $script:Config
    $ehTI = ($script:Contexto.Perfil -ne 'Usuario')
    $opcoes = New-Object System.Collections.Generic.List[object]
    switch ($Id) {
        'LimpezaTemporarios' {
            $opcoes.Add([pscustomobject]@{ Id = 'TempUsuario'; Texto = 'Temporários do usuário'; Dica = 'Arquivos temporários da sua conta.'; Marcado = $true; Habilitado = $true })
            $opcoes.Add([pscustomobject]@{ Id = 'TempWindows'; Texto = 'Temporários do Windows (exige administrador)'; Dica = 'Pasta Temp do sistema. O Windows pedirá autorização de administrador.'; Marcado = $false; Habilitado = [bool]$cfg.Limpeza.PermitirTempWindows })
            $opcoes.Add([pscustomobject]@{ Id = 'Lixeira'; Texto = 'Esvaziar a Lixeira'; Dica = 'Os itens da Lixeira não poderão ser recuperados.'; Marcado = $true; Habilitado = [bool]$cfg.Limpeza.PermitirLixeira })
        }
        'Impressoras' {
            $opcoes.Add([pscustomobject]@{ Id = '__TODAS__'; Texto = 'Selecionar todas'; Dica = ''; Marcado = $false; Habilitado = $true })
            foreach ($imp in @($cfg.Impressoras | Where-Object { $_.Habilitada })) {
                $dica = @()
                if (-not (Test-ValorPendente $imp.Localizacao)) { $dica += ('Local: {0}' -f $imp.Localizacao) }
                if ($ehTI) { $dica += ('IP: {0} - Driver: {1}' -f $imp.IP, $imp.Driver) }
                $opcoes.Add([pscustomobject]@{ Id = [string]$imp.Id; Texto = [string]$imp.Nome; Dica = ($dica -join '  |  '); Marcado = $false; Habilitado = $true })
            }
        }
        'AbrirPastas' {
            foreach ($c in (Get-CompartilhamentosPermitidos -Perfil $script:Contexto.Perfil)) {
                $dica = if ($ehTI) { [string]$c.Caminho } else { '' }
                $opcoes.Add([pscustomobject]@{ Id = [string]$c.Id; Texto = [string]$c.Nome; Dica = $dica; Marcado = $true; Habilitado = $true })
            }
        }
    }
    return $opcoes.ToArray()
}

function Show-PainelAcao {
    param([string]$Id)
    if ($script:Operacao) { return }
    $acao = Get-AcaoCatalogo -Id $Id
    if (-not $acao) { return }
    $script:AcaoAtual = $acao

    $script:UI.TxtAcaoIcone.Text = [string][char]$acao.Icone
    $script:UI.TxtAcaoTitulo.Text = $acao.Titulo
    $script:UI.TxtAcaoDescricao.Text = $acao.Descricao
    $script:UI.TxtAdmin.Text = $acao.Admin
    $script:UI.TxtBotaoExecutar.Text = $acao.Botao

    # Credenciais
    $mostrarCredencial = ($acao.Campos -eq 'Credencial') -or ($acao.Campos -eq 'CredencialAD' -and [string]$script:Config.ServidorAD.ModoAbertura -eq 'OutroUsuario')
    $script:UI.PainelCredencial.Visibility = $(if ($mostrarCredencial) { 'Visible' } else { 'Collapsed' })
    $script:UI.TxtUsuario.Text = ''
    $script:UI.PwdSenha.Clear()
    $script:UI.PainelCapsLock.Visibility = 'Collapsed'
    if ($acao.PSObject.Properties['RotuloUsuario'] -and $acao.RotuloUsuario) { $script:UI.LblUsuario.Text = $acao.RotuloUsuario }
    $script:UI.TxtUsuarioDica.Text = ('Exemplo: joao.silva (o domínio {0} é adicionado automaticamente).' -f $script:Config.Dominio.NetBIOS)

    # Opções
    $script:UI.ListaOpcoes.Children.Clear()
    $opcoes = @(Get-OpcoesAcao -Id $Id)
    if ($opcoes.Count -gt 0) {
        $script:UI.PainelOpcoes.Visibility = 'Visible'
        $script:UI.TxtOpcoesTitulo.Text = $(switch ($Id) { 'Impressoras' { 'Impressoras disponíveis' } 'AbrirPastas' { 'Pastas autorizadas' } default { 'O que deseja limpar?' } })
        foreach ($o in $opcoes) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Tag = $o.Id
            $cb.IsChecked = $o.Marcado
            $cb.IsEnabled = $o.Habilitado
            [System.Windows.Automation.AutomationProperties]::SetName($cb, $o.Texto)
            $conteudo = New-Object System.Windows.Controls.StackPanel
            $conteudo.Margin = '6,0,0,0'
            [void]$conteudo.Children.Add((New-TextBlock -Texto $o.Texto -Peso 'SemiBold'))
            if ($o.Dica) { [void]$conteudo.Children.Add((New-TextBlock -Texto $o.Dica -Tamanho 12 -CorRecurso 'BrushTextoSecundario')) }
            if (-not $o.Habilitado) { [void]$conteudo.Children.Add((New-TextBlock -Texto 'Desativado pela TI.' -Tamanho 12 -CorRecurso 'BrushAviso')) }
            $cb.Content = $conteudo
            if ($o.Id -eq '__TODAS__') {
                $cb.Add_Click({
                        param($origem, $evento)
                        foreach ($outro in $script:UI.ListaOpcoes.Children) {
                            if ($outro.Tag -ne '__TODAS__' -and $outro.IsEnabled) { $outro.IsChecked = $origem.IsChecked }
                        }
                    })
            }
            [void]$script:UI.ListaOpcoes.Children.Add($cb)
        }
    }
    else {
        $script:UI.PainelOpcoes.Visibility = 'Collapsed'
    }

    # Botão secundário
    $sec = $acao.Secundaria
    $mostrarSec = $false
    if ($sec) {
        $mostrarSec = ($sec.Tipo -eq 'Local') -or (Test-PermissaoRecurso -Id $sec.Alvo)
        $script:UI.TxtBotaoSecundaria.Text = $sec.Texto
    }
    $script:UI.BtnSecundaria.Visibility = $(if ($mostrarSec) { 'Visible' } else { 'Collapsed' })

    # Limpa resultado anterior
    $script:UI.BordaResultado.Visibility = 'Collapsed'
    $script:UI.TxtSaida.Visibility = 'Collapsed'
    $script:UI.TxtSaida.Text = ''

    $script:UI.PainelMenu.Visibility = 'Collapsed'
    $script:UI.PainelAcao.Visibility = 'Visible'
    $script:UI.PainelAcao.ScrollToTop()
    $script:UI.BtnExecutar.IsDefault = $true
    if ($mostrarCredencial) { [void]$script:UI.TxtUsuario.Focus() } else { [void]$script:UI.BtnExecutar.Focus() }
}

function Get-OpcoesMarcadas {
    $ids = @()
    foreach ($cb in $script:UI.ListaOpcoes.Children) {
        if ($cb.IsChecked -and $cb.IsEnabled -and $cb.Tag -ne '__TODAS__') { $ids += [string]$cb.Tag }
    }
    return , $ids
}

function Get-TextoConfirmacao {
    param([object]$Acao, [string[]]$Ids)
    switch ($Acao.Id) {
        'LimpezaTemporarios' {
            $nomes = @()
            if ($Ids -contains 'TempUsuario') { $nomes += '- Temporários do usuário' }
            if ($Ids -contains 'TempWindows') { $nomes += '- Temporários do Windows (pedirá autorização de administrador)' }
            if ($Ids -contains 'Lixeira') { $nomes += '- Lixeira (os itens NÃO poderão ser recuperados)' }
            return ("Serão limpos:`n{0}`n`nArquivos em uso por programas abertos serão preservados.`n`nDeseja continuar?" -f ($nomes -join "`n"))
        }
        'Impressoras' {
            return ("Serão verificadas/instaladas {0} impressora(s).`nSe for preciso instalar, o Windows pedirá autorização de administrador.`n`nDeseja continuar?" -f $Ids.Count)
        }
        'InstalarRSAT' {
            return "O RSAT do Active Directory será instalado pelo Windows Update/WSUS.`nIsso exige administrador e pode levar vários minutos.`n`nDeseja continuar?"
        }
        default { return [string]$Acao.Confirmacao }
    }
}

function Show-Resultado {
    param([object]$Resultado)
    $mapa = @{
        Sucesso   = @{ Icone = 0xE73E; Titulo = 'Concluído com sucesso';       Cor = 'BrushSucesso'; Status = 'Sucesso' }
        Aviso     = @{ Icone = 0xE7BA; Titulo = 'Concluído com observações';   Cor = 'BrushAviso';   Status = 'Aviso' }
        Parcial   = @{ Icone = 0xE7BA; Titulo = 'Concluído parcialmente';      Cor = 'BrushAviso';   Status = 'Aviso' }
        Falha     = @{ Icone = 0xE783; Titulo = 'Não foi possível concluir';   Cor = 'BrushErro';    Status = 'Erro' }
        Cancelado = @{ Icone = 0xE711; Titulo = 'Cancelado';                   Cor = 'BrushAviso';   Status = 'Aviso' }
        Negado    = @{ Icone = 0xE72E; Titulo = 'Acesso negado';               Cor = 'BrushErro';    Status = 'Erro' }
    }
    $m = $mapa[[string]$Resultado.Status]
    if (-not $m) { $m = $mapa['Falha'] }

    $script:UltimoResultado = $Resultado
    $script:UI.TxtResultadoIcone.Text = [string][char]$m.Icone
    $script:UI.TxtResultadoIcone.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $m.Cor)
    $script:UI.TxtResultadoTitulo.Text = $m.Titulo
    $script:UI.BordaResultado.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, $m.Cor)
    $script:UI.TxtResultadoMensagem.Text = [string]$Resultado.Mensagem
    $itens = @($Resultado.Itens | Where-Object { $_ })
    $script:UI.TxtResultadoItens.Text = ($itens -join [Environment]::NewLine)
    $script:UI.TxtResultadoItens.Visibility = $(if ($itens.Count) { 'Visible' } else { 'Collapsed' })
    $script:UI.TxtResultadoRecomendacao.Text = [string]$Resultado.Recomendacao
    $script:UI.BordaRecomendacao.Visibility = $(if ($Resultado.Recomendacao) { 'Visible' } else { 'Collapsed' })
    $script:UI.BordaResultado.Visibility = 'Visible'

    if ($Resultado.Saida) {
        $script:UI.TxtSaida.Text = [string]$Resultado.Saida
        $script:UI.TxtSaida.Visibility = 'Visible'
    }

    Set-Status -Texto ('{0}: {1}' -f $m.Titulo, $Resultado.Mensagem) -Tipo $m.Status
    Add-Atividade ('{0} — {1}' -f $m.Titulo, $Resultado.Mensagem)
    $script:UI.BordaResultado.BringIntoView()
}

function Copy-DetalhesTecnicos {
    <# Copia detalhes técnicos da última execução. Nunca inclui senha/credencial. #>
    $r = $script:UltimoResultado
    if (-not $r) { return }
    $ctx = $script:Contexto
    $texto = @(
        ('{0} {1}' -f $script:Config.Aplicacao.Nome, $script:Config.Aplicacao.Versao)
        ('Data/hora ....: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('Computador ...: {0}' -f $ctx.Computador)
        ('Usuário ......: {0}' -f $ctx.Usuario)
        ('Perfil .......: {0}' -f $ctx.Perfil)
        ('Função .......: {0}' -f $script:UltimaAcaoExecutada)
        ('Resultado ....: {0}' -f $r.Status)
        ('Elevação .....: {0}' -f $r.Elevacao)
        ('Código erro ..: {0}' -f $r.CodigoErro)
        ('Mensagem .....: {0}' -f $r.Mensagem)
        'Itens:'
        (@($r.Itens) -join [Environment]::NewLine)
        'Detalhes técnicos:'
        [string]$r.Detalhes
    ) -join [Environment]::NewLine
    $texto = Protect-TextoSensivel $texto
    for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
        try {
            [System.Windows.Clipboard]::SetText($texto)
            Add-Atividade 'Detalhes técnicos copiados para a área de transferência.'
            return
        }
        catch { Start-Sleep -Milliseconds 150 }
    }
    Add-Atividade 'Não foi possível copiar (área de transferência ocupada). Tente de novo.'
}

function Set-Ocupado {
    param([bool]$Ocupado, [string]$Texto = '')
    $livre = -not $Ocupado
    foreach ($n in 'BtnExecutar', 'BtnSecundaria', 'BtnVoltar', 'PainelNav', 'PainelCredencial', 'ListaOpcoes', 'BtnCopiarDetalhes', 'PainelCartoes') {
        $script:UI[$n].IsEnabled = $livre
    }
    $script:UI.BarraProgresso.Visibility = $(if ($Ocupado) { 'Visible' } else { 'Collapsed' })
    $script:UI.BarraProgresso.IsIndeterminate = $Ocupado
    $script:UI.BarraProgresso.Value = 0
    $script:Janela.Cursor = $(if ($Ocupado) { [System.Windows.Input.Cursors]::AppStarting } else { $null })
    if ($Ocupado) { Set-Status -Texto ('Em execução: {0}...' -f $Texto) -Tipo Processando }
}

function Update-ProgressoUI {
    param([object]$Item)
    if ($Item.Tipo -eq 'Atividade') { Add-Atividade $Item.Texto; return }
    if ($script:Operacao) {
        Set-Status -Texto $Item.Texto -Tipo Processando
        if ($Item.Percentual -ge 0) {
            $script:UI.BarraProgresso.IsIndeterminate = $false
            $script:UI.BarraProgresso.Value = [Math]::Min(100, $Item.Percentual)
        }
        else {
            $script:UI.BarraProgresso.IsIndeterminate = $true
        }
    }
}

#endregion

#region Execução em segundo plano ---------------------------------------------

# Código executado no runspace de trabalho. Recebe só objetos (nenhum
# texto é concatenado em comando) e importa os mesmos módulos.
$script:ScriptOperacao = {
    param($AppRoot, $Modulos, $Config, $Fila, $Id, $Parametros)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    foreach ($m in $Modulos) {
        Import-Module -Name (Join-Path $AppRoot ('modules\SuporteTI.{0}.psm1' -f $m)) -Global -Force -DisableNameChecking
    }
    [void](Initialize-SuporteContexto -Config $Config -AppRoot $AppRoot -Fila $Fila)
    Invoke-AcaoSuporte -Id $Id -Parametros $Parametros
}

function Start-OperacaoSegundoPlano {
    param([string]$Id, [hashtable]$Parametros, [string]$Titulo)
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($script:ScriptOperacao.ToString())
    [void]$ps.AddParameters(@{
            AppRoot    = $script:AppRoot
            Modulos    = $script:Modulos
            Config     = $script:Config
            Fila       = $script:Fila
            Id         = $Id
            Parametros = $Parametros
        })
    $script:UltimaAcaoExecutada = $Id
    $script:Operacao = @{ PS = $ps; Runspace = $runspace; Handle = $ps.BeginInvoke(); Id = $Id; Titulo = $Titulo }
    Add-Atividade ('Iniciado: {0}' -f $Titulo)
}

function Complete-Operacao {
    $op = $script:Operacao
    $resultado = $null
    try {
        $saida = $op.PS.EndInvoke($op.Handle)
        $resultado = @($saida | Where-Object { $_ -and $_.PSObject.Properties['Status'] -and $_.PSObject.Properties['Mensagem'] }) | Select-Object -Last 1
        if (-not $resultado) {
            $erros = @($op.PS.Streams.Error | ForEach-Object { $_.ToString() }) -join ' | '
            $resultado = New-ResultadoAcao -Status Falha -Mensagem 'A operação terminou sem resultado.' `
                -Recomendacao 'Copie os detalhes técnicos e envie para a TI.' -Detalhes $erros
        }
    }
    catch {
        $resultado = New-ResultadoAcao -Status Falha -Mensagem 'Ocorreu um erro inesperado.' `
            -Recomendacao 'Copie os detalhes técnicos e envie para a TI.' -Detalhes (Get-MensagemInterna $_.Exception)
        Write-SuporteLog -Funcao $op.Id -Resultado Falha -Mensagem ('Falha no runspace: {0}' -f (Get-MensagemInterna $_.Exception))
    }
    finally {
        try { $op.PS.Dispose() } catch { }
        try { $op.Runspace.Dispose() } catch { }
        $script:Operacao = $null
    }

    # Esvazia mensagens que ainda estavam na fila
    $item = $null
    while ($script:Fila.TryDequeue([ref]$item)) { Update-ProgressoUI $item }

    Set-Ocupado $false
    Show-Resultado $resultado

    # Pós-ação na interface (somente ações da lista fixa)
    if ($resultado.PosAcao -and $resultado.PosAcao.Tipo -eq 'PainelImpressoras') {
        try { [System.Windows.Clipboard]::SetText([string]$resultado.PosAcao.Valor) } catch { }
        try { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\control.exe') -ArgumentList 'printers' } catch { }
        Add-Atividade 'Painel de impressoras aberto para instalação manual (endereço copiado).'
    }
}

function Invoke-AcaoUI {
    <# Valida na interface, confirma, e dispara a execução em segundo plano. #>
    param([string]$Id)
    if ($script:Operacao) { Add-Atividade 'Aguarde a operação atual terminar.'; return }
    $acao = Get-AcaoCatalogo -Id $Id
    if (-not $acao) { return }

    # 1) Permissão (de novo, além de esconder o botão)
    if (-not (Test-PermissaoRecurso -Id $Id)) {
        $script:UltimaAcaoExecutada = $Id
        Show-Resultado (New-ResultadoAcao -Status Negado -Mensagem 'Você não tem permissão para usar esta função.' -Recomendacao 'Se precisar dela, abra um chamado para a TI.')
        Write-SuporteLog -Funcao $Id -Resultado Negado -Mensagem 'Bloqueado na interface (perfil sem permissão).'
        return
    }

    # 2) Entradas
    $parametros = @{ Ids = @() }
    $usaCredencial = ($acao.Campos -eq 'Credencial') -or ($acao.Campos -eq 'CredencialAD' -and [string]$script:Config.ServidorAD.ModoAbertura -eq 'OutroUsuario')
    if ($script:UI.PainelOpcoes.Visibility -eq 'Visible') {
        $parametros.Ids = Get-OpcoesMarcadas
        if ($parametros.Ids.Count -eq 0) {
            $script:UltimaAcaoExecutada = $Id
            Show-Resultado (New-ResultadoAcao -Status Aviso -Mensagem 'Selecione ao menos uma opção.')
            return
        }
    }
    if ($usaCredencial) {
        $usuario = ConvertTo-UsuarioDominio -Entrada $script:UI.TxtUsuario.Text -Config $script:Config
        if (-not $usuario.Valido) {
            $script:UltimaAcaoExecutada = $Id
            Show-Resultado (New-ResultadoAcao -Status Aviso -Mensagem $usuario.Mensagem -Recomendacao 'Digite apenas o seu usuário de rede, por exemplo: joao.silva')
            [void]$script:UI.TxtUsuario.Focus()
            return
        }
        $copiaSenha = $script:UI.PwdSenha.SecurePassword
        $senhaVazia = ($copiaSenha.Length -eq 0)
        $copiaSenha.Dispose()
        if ($senhaVazia) {
            $script:UltimaAcaoExecutada = $Id
            Show-Resultado (New-ResultadoAcao -Status Aviso -Mensagem 'Informe a senha.')
            [void]$script:UI.PwdSenha.Focus()
            return
        }
        $script:UI.TxtUsuario.Text = $usuario.Completo   # mostra como foi normalizado
    }

    # 3) Confirmação
    $confirmacao = Get-TextoConfirmacao -Acao $acao -Ids $parametros.Ids
    if ($confirmacao) {
        $resposta = [System.Windows.MessageBox]::Show($script:Janela, $confirmacao, $acao.Titulo, 'YesNo', 'Question', 'No')
        if ($resposta -ne 'Yes') {
            Add-Atividade ('Cancelado pelo usuário: {0}' -f $acao.Titulo)
            Write-SuporteLog -Funcao $Id -Resultado Cancelado -Mensagem 'Cancelado na confirmação.'
            return
        }
    }

    # 4) Senha: SecureString somente leitura, retirada da caixa logo em seguida
    if ($usaCredencial) {
        $senha = $script:UI.PwdSenha.SecurePassword
        $senha.MakeReadOnly()
        $parametros.Usuario = $script:UI.TxtUsuario.Text
        $parametros.Senha = $senha
        $script:UI.PwdSenha.Clear()
    }

    Set-Ocupado $true $acao.Titulo
    Start-OperacaoSegundoPlano -Id $Id -Parametros $parametros -Titulo $acao.Titulo
}

function Invoke-AcaoSecundaria {
    $acao = $script:AcaoAtual
    if (-not $acao -or -not $acao.Secundaria -or $script:Operacao) { return }
    $sec = $acao.Secundaria
    if ($sec.Tipo -eq 'Local' -and $sec.Alvo -eq 'AbrirPastaLogs') {
        if (-not (Test-PermissaoRecurso -Id 'VerLogs')) { return }
        $dir = $script:Contexto.DiretorioLog
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $dir)
            Add-Atividade 'Pasta de logs aberta.'
        }
        return
    }
    if ($sec.Tipo -eq 'Acao') {
        $alvo = Get-AcaoCatalogo -Id $sec.Alvo
        $titulo = if ($alvo) { $alvo.Titulo } else { $sec.Texto }
        if (-not (Test-PermissaoRecurso -Id $sec.Alvo)) {
            $script:UltimaAcaoExecutada = $sec.Alvo
            Show-Resultado (New-ResultadoAcao -Status Negado -Mensagem 'Você não tem permissão para usar esta função.')
            Write-SuporteLog -Funcao $sec.Alvo -Resultado Negado -Mensagem 'Bloqueado na interface (perfil sem permissão).'
            return
        }
        $confirmacao = Get-TextoConfirmacao -Acao ([pscustomobject]@{ Id = $sec.Alvo; Confirmacao = '' }) -Ids @()
        if ($confirmacao) {
            $resposta = [System.Windows.MessageBox]::Show($script:Janela, $confirmacao, $sec.Texto, 'YesNo', 'Question', 'No')
            if ($resposta -ne 'Yes') { Add-Atividade ('Cancelado pelo usuário: {0}' -f $sec.Texto); return }
        }
        Set-Ocupado $true $sec.Texto
        Start-OperacaoSegundoPlano -Id $sec.Alvo -Parametros @{ Ids = @() } -Titulo $titulo
    }
}

#endregion

#region Inicialização ----------------------------------------------------------

try {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'A aplicação precisa ser iniciada em modo STA. Use o atalho oficial ou Iniciar-SuporteTI.bat.'
    }

    foreach ($m in $script:Modulos) {
        Import-Module -Name (Join-Path $script:AppRoot ('modules\SuporteTI.{0}.psm1' -f $m)) -Global -Force -DisableNameChecking
    }

    $script:Config = Import-SuporteConfig -Caminho (Join-Path $script:AppRoot 'config\SuporteTI.config.psd1')

    # Uma instância por usuário
    $criado = $false
    $script:MutexInstancia = New-Object System.Threading.Mutex($true, 'Local\EVEN_SuporteTI_Instancia', [ref]$criado)
    if (-not $criado) {
        [void][System.Windows.MessageBox]::Show('A Central de Suporte TI já está aberta.', $script:Config.Aplicacao.Nome, 'OK', 'Information')
        exit 0
    }

    $script:Contexto = Initialize-SuporteContexto -Config $script:Config -AppRoot $script:AppRoot -Fila $script:Fila
    Remove-LogsAntigos
    Write-SuporteLog -Funcao 'Aplicacao' -Resultado Info -Mensagem ('Aplicação iniciada. Perfil: {0} ({1}). Elevado: {2}.' -f $script:Contexto.Perfil, $script:Contexto.MotivoPerfil, (Test-Administrador))

    if ($script:Config.Aplicacao.OcultarConsole) { [EvenSuporte.Nativo]::OcultarConsole() }

    # Janela
    $caminhoXaml = Join-Path $script:AppRoot 'ui\MainWindow.xaml'
    [xml]$xaml = [IO.File]::ReadAllText($caminhoXaml, [Text.Encoding]::UTF8)
    $leitor = New-Object System.Xml.XmlNodeReader $xaml
    $script:Janela = [System.Windows.Markup.XamlReader]::Load($leitor)

    $nomes = 'ImgLogo', 'LogoPlaceholder', 'TxtTituloApp', 'TxtSubtituloApp', 'TxtPerfilBadge', 'BordaPerfil',
             'BannerHomologacao', 'TxtBanner', 'PainelNav', 'BtnNavInicio', 'BtnNavAcesso', 'BtnNavUsuario', 'BtnNavTI',
             'PainelMenu', 'TxtSecaoTitulo', 'TxtSecaoDescricao', 'PainelCartoes',
             'PainelAcao', 'BtnVoltar', 'TxtAcaoIcone', 'TxtAcaoTitulo', 'TxtAcaoDescricao', 'BordaAdmin', 'TxtAdmin',
             'PainelCredencial', 'LblUsuario', 'TxtUsuario', 'TxtUsuarioDica', 'PwdSenha', 'PainelCapsLock',
             'PainelOpcoes', 'TxtOpcoesTitulo', 'ListaOpcoes', 'BtnExecutar', 'TxtBotaoExecutar', 'BtnSecundaria', 'TxtBotaoSecundaria',
             'BordaResultado', 'TxtResultadoIcone', 'TxtResultadoTitulo', 'TxtResultadoMensagem', 'TxtResultadoItens',
             'BordaRecomendacao', 'TxtResultadoRecomendacao', 'BtnCopiarDetalhes', 'TxtSaida',
             'TxtStatusIcone', 'TxtStatus', 'BarraProgresso', 'ExpAtividades', 'ListaAtividades', 'TxtRodape', 'TxtEstado'
    $script:UI = @{}
    foreach ($n in $nomes) {
        $controle = $script:Janela.FindName($n)
        if (-not $controle) { throw ('Elemento "{0}" não encontrado em MainWindow.xaml.' -f $n) }
        $script:UI[$n] = $controle
    }

    # Tema a partir da configuração
    $v = $script:Config.Visual
    $cores = @{
        BrushPrimaria = 'CorPrimaria'; BrushPrimariaEscura = 'CorPrimariaEscura'; BrushPreto = 'CorPreta'; BrushBranco = 'CorBranca'
        BrushCinzaClaro = 'CorCinzaClaro'; BrushSucesso = 'CorSucesso'; BrushAviso = 'CorAviso'; BrushErro = 'CorErro'
    }
    foreach ($chave in $cores.Keys) {
        $cor = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString([string]$v[$cores[$chave]])
        $pincel = New-Object System.Windows.Media.SolidColorBrush($cor)
        $pincel.Freeze()
        $script:Janela.Resources[$chave] = $pincel
    }

    # Logotipo (opcional)
    $logo = [string]$v.CaminhoLogotipo
    if (-not (Test-ValorPendente $logo)) {
        $caminhoLogo = if ([IO.Path]::IsPathRooted($logo)) { $logo } else { Join-Path $script:AppRoot $logo }
        if (Test-Path -LiteralPath $caminhoLogo -PathType Leaf) {
            try {
                $imagem = New-Object System.Windows.Media.Imaging.BitmapImage
                $imagem.BeginInit()
                $imagem.CacheOption = 'OnLoad'
                $imagem.UriSource = New-Object System.Uri($caminhoLogo)
                $imagem.EndInit()
                $script:UI.ImgLogo.Source = $imagem
                $script:UI.ImgLogo.Visibility = 'Visible'
                $script:UI.LogoPlaceholder.Visibility = 'Collapsed'
            }
            catch { Write-SuporteLog -Funcao 'Aplicacao' -Resultado Aviso -Mensagem ('Logotipo não carregado: {0}' -f $_.Exception.Message) }
        }
    }

    # Textos fixos
    $nomesPerfil = @{ Usuario = 'Usuário'; Tecnico = 'Técnico de TI'; Administrador = 'Administrador' }
    $script:Janela.Title = $script:Config.Aplicacao.Nome
    $script:UI.TxtTituloApp.Text = $script:Config.Aplicacao.Nome
    $script:UI.TxtPerfilBadge.Text = $nomesPerfil[$script:Contexto.Perfil]
    $script:UI.TxtRodape.Text = ('Versão {0}   •   Computador: {1}   •   Usuário: {2}   •   Perfil: {3}' -f `
            $script:Config.Aplicacao.Versao, $script:Contexto.Computador, $script:Contexto.Usuario, $nomesPerfil[$script:Contexto.Perfil])

    $temTI = @(Get-AcoesVisiveis -Grupo 'TI').Count -gt 0
    $script:UI.BtnNavTI.Visibility = $(if ($temTI) { 'Visible' } else { 'Collapsed' })

    if ($script:Contexto.Perfil -ne 'Usuario' -and -not $script:Config.Aplicacao.ValoresConfirmadosPelaTI) {
        $qtd = @(Get-ValoresPendentes -No $script:Config).Count
        $script:UI.TxtBanner.Text = ('Modo homologação: servidores, IPs e caminhos herdados da BAT ainda não foram confirmados e há {0} valor(es) TODO_VALIDAR na configuração. Veja "Diagnósticos administrativos".' -f $qtd)
        $script:UI.BannerHomologacao.Visibility = 'Visible'
    }

    # Eventos
    $script:UI.BtnNavInicio.Add_Click({ Show-Menu -Grupo Todos })
    $script:UI.BtnNavAcesso.Add_Click({ Show-Menu -Grupo Acesso })
    $script:UI.BtnNavUsuario.Add_Click({ Show-Menu -Grupo Usuario })
    $script:UI.BtnNavTI.Add_Click({ Show-Menu -Grupo TI })
    $script:UI.BtnVoltar.Add_Click({ Show-Menu -Grupo Todos })
    $script:UI.BtnExecutar.Add_Click({ if ($script:AcaoAtual) { Invoke-AcaoUI -Id $script:AcaoAtual.Id } })
    $script:UI.BtnSecundaria.Add_Click({ Invoke-AcaoSecundaria })
    $script:UI.BtnCopiarDetalhes.Add_Click({ Copy-DetalhesTecnicos })

    $verificarCaps = {
        $ativo = [System.Windows.Input.Keyboard]::IsKeyToggled([System.Windows.Input.Key]::CapsLock)
        $script:UI.PainelCapsLock.Visibility = $(if ($ativo) { 'Visible' } else { 'Collapsed' })
    }
    $script:UI.PwdSenha.Add_KeyUp($verificarCaps)
    $script:UI.PwdSenha.Add_GotKeyboardFocus($verificarCaps)

    $script:Janela.Add_KeyDown({
            param($origem, $evento)
            if ($evento.Key -eq [System.Windows.Input.Key]::Escape -and -not $script:Operacao -and $script:UI.PainelAcao.Visibility -eq 'Visible') {
                Show-Menu -Grupo Todos
                $evento.Handled = $true
            }
        })

    $script:Janela.Add_Closing({
            param($origem, $evento)
            if ($script:Operacao) {
                [void][System.Windows.MessageBox]::Show($script:Janela, 'Há uma operação em andamento. Aguarde terminar para fechar.', $script:Config.Aplicacao.Nome, 'OK', 'Warning')
                $evento.Cancel = $true
            }
        })

    # Timer da interface: lê a fila de progresso e detecta o fim da operação
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:Timer.Add_Tick({
            try {
                $item = $null
                while ($script:Fila.TryDequeue([ref]$item)) { Update-ProgressoUI $item }
                if ($script:Operacao -and $script:Operacao.Handle.IsCompleted) { Complete-Operacao }
            }
            catch {
                Write-SuporteLog -Funcao 'Interface' -Resultado Falha -Mensagem ('Erro no timer: {0}' -f (Get-MensagemInterna $_.Exception))
            }
        })
    $script:Timer.Start()

    Show-Menu -Grupo Todos
    Set-Status -Texto 'Pronto. Escolha uma função.' -Tipo Pronto
    Add-Atividade ('Bem-vindo(a). Perfil: {0}.' -f $nomesPerfil[$script:Contexto.Perfil])

    [void]$script:Janela.ShowDialog()

    $script:Timer.Stop()
    Write-SuporteLog -Funcao 'Aplicacao' -Resultado Info -Mensagem 'Aplicação encerrada.'
    $codigoSaida = 0
}
catch {
    $mensagem = $_.Exception.Message
    try { Write-SuporteLog -Funcao 'Aplicacao' -Resultado Falha -Mensagem ('Falha ao iniciar: {0}' -f $mensagem) } catch { }
    Show-ErroFatal ("Não foi possível abrir a Central de Suporte TI.`n`n{0}`n`nSe o problema continuar, avise a equipe de TI." -f $mensagem)
    $codigoSaida = 10
}
finally {
    if ($script:MutexInstancia) {
        try { $script:MutexInstancia.ReleaseMutex() } catch { }
        $script:MutexInstancia.Dispose()
    }
}
exit $codigoSaida

#endregion
