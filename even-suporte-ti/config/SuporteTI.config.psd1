# =====================================================================
#  Central de Suporte TI - EVEN  —  CONFIGURAÇÃO CENTRALIZADA
#  Arquivo: config\SuporteTI.config.psd1
# ---------------------------------------------------------------------
#  * Somente DADOS (sem código). É lido com Import-PowerShellDataFile,
#    que não executa comandos. Mesmo assim, guarde este arquivo em pasta
#    onde só administradores possam gravar (ex.: C:\Program Files\...),
#    porque ele define servidores, IPs e drivers usados em ações elevadas.
#  * TODO_VALIDAR = valor ainda não fornecido/confirmado pela TI da EVEN.
#    A função que depende de um valor TODO_VALIDAR fica BLOQUEADA, com
#    mensagem amigável, até a configuração ser concluída.
#  * "Herdado da BAT" = valor copiado SEM ALTERAÇÃO da BAT original.
#    NÃO foi confirmado como atual. Revise antes da produção.
#  * NUNCA coloque senhas neste arquivo.
#  * Salve em UTF-8 COM BOM (o PowerShell 5.1 precisa disso para acentos).
#  * Para desativar uma função obsoleta sem apagar código, use
#    Recursos.<Função>.Habilitado = $false (seção no final do arquivo).
# =====================================================================
@{
    # -----------------------------------------------------------------
    # Aplicação
    # -----------------------------------------------------------------
    Aplicacao = @{
        Nome    = 'Central de Suporte TI - EVEN'
        Empresa = 'EVEN'
        Versao  = '1.0.0-homologacao'

        # Mude para $true SOMENTE depois que a TI confirmar todos os
        # valores herdados da BAT. Enquanto $false, técnicos e
        # administradores veem um aviso de homologação na tela.
        ValoresConfirmadosPelaTI = $false

        # Ações que exigem administrador (Temp do Windows, impressoras,
        # RSAT) só são executadas se a aplicação estiver numa pasta
        # protegida (Program Files ou uma das PastasConfiaveis abaixo).
        # Evita que um administrador rode, elevado, um script que um
        # usuário comum conseguiu alterar.
        ExigirPastaProtegidaParaElevacao = $true

        # Pastas adicionais em que só administradores podem gravar.
        # Exemplo: @('D:\Apps\EVEN\SuporteTI')
        PastasConfiaveis = @()

        # Oculta a janela preta do console quando a interface abre.
        OcultarConsole = $true
    }

    # -----------------------------------------------------------------
    # Identidade visual
    # -----------------------------------------------------------------
    Visual = @{
        # >>> PROVISÓRIO — TODO_VALIDAR: substituir pelo HEX OFICIAL do
        # >>> "verde Guatemala" do manual de marca da EVEN.
        # >>> Este valor NÃO é o código oficial; é só um verde escuro
        # >>> temporário para a homologação.
        CorPrimaria       = '#0B6E4F'
        # Tom mais escuro da cor primária (efeito ao passar o mouse).
        # PROVISÓRIO — recalcular a partir do HEX oficial.
        CorPrimariaEscura = '#084F39'

        CorPreta      = '#000000'
        CorBranca     = '#FFFFFF'
        CorCinzaClaro = '#F2F2F2'

        # Cores de estado (sempre acompanhadas de ícone e texto).
        CorSucesso = '#0B6E4F'
        CorAviso   = '#8A5A00'
        CorErro    = '#B00020'

        # Caminho do logotipo (PNG recomendado, fundo transparente,
        # ~ 200 x 60 px). Relativo à pasta da aplicação ou absoluto.
        # Vazio ou TODO_VALIDAR = mostra o espaço reservado "LOGO".
        CaminhoLogotipo = 'TODO_VALIDAR'
    }

    # -----------------------------------------------------------------
    # Domínio do Active Directory
    # -----------------------------------------------------------------
    Dominio = @{
        # Herdado da BAT (EVENSP\usuario). TODO_VALIDAR: confirmar.
        NetBIOS = 'EVENSP'
        # TODO_VALIDAR: nome DNS completo do domínio (ex.: corp.exemplo.com.br)
        FQDN = 'TODO_VALIDAR'
        # TODO_VALIDAR: sufixos UPN aceitos quando o usuário digitar
        # usuario@sufixo. Enquanto pendente, qualquer sufixo é aceito e
        # descartado (comportamento da BAT), assumindo que o prefixo do
        # UPN é igual ao sAMAccountName.
        SufixosUPN = @('TODO_VALIDAR')

        # Confere usuário/senha no domínio ANTES de salvar a credencial.
        # Atenção: uma senha errada conta como tentativa para bloqueio
        # de conta, como qualquer login.
        ValidarSenhaNoDominio = $true

        # Se o domínio estiver inacessível (fora da rede/VPN), permite
        # salvar a credencial mesmo sem conferir, com aviso.
        PermitirSalvarSemValidar = $true

        # Tamanho máximo do nome de usuário (sAMAccountName = 20).
        TamanhoMaximoUsuario = 20
    }

    # -----------------------------------------------------------------
    # Perfis de acesso (grupos do AD)
    # Prefira o SID: funciona fora da rede e não depende de nome.
    # Descubra o SID com:  (Get-ADGroup 'NomeDoGrupo').SID.Value
    # Sem grupo configurado, ninguém vira Técnico/Administrador
    # (comportamento seguro).
    # -----------------------------------------------------------------
    Perfis = @{
        GrupoTecnicos = @{
            SID  = 'TODO_VALIDAR'
            Nome = 'TODO_VALIDAR'      # ex.: EVENSP\GG-TI-Suporte
        }
        GrupoAdministradores = @{
            SID  = 'TODO_VALIDAR'
            Nome = 'TODO_VALIDAR'      # ex.: EVENSP\GG-TI-Admins
        }
        # Somente para HOMOLOGAÇÃO: trata quem executa a ferramenta
        # elevado (administrador local) como Técnico. Manter $false em
        # produção.
        ConsiderarAdminLocalElevadoComoTecnico = $false
    }

    # -----------------------------------------------------------------
    # Gerenciador de Credenciais do Windows
    # -----------------------------------------------------------------
    Credenciais = @{
        # $true = persistência "Enterprise" (igual ao cmdkey /add; acompanha
        # perfil móvel). $false = somente neste computador.
        PersistenciaEnterprise = $true
    }

    # -----------------------------------------------------------------
    # Cubo
    # -----------------------------------------------------------------
    Cubo = @{
        # Herdado da BAT. TODO_VALIDAR: servidor atual do Cubo.
        Servidor = 'SSPDW01'
        # TODO_VALIDAR: porta TCP para teste de conectividade do Cubo
        # (ex.: 2383 para SSAS, 443 para HTTPS). 0 = não testar.
        PortaTeste = 0
    }

    # -----------------------------------------------------------------
    # Servidor de administração do Active Directory
    # -----------------------------------------------------------------
    ServidorAD = @{
        # Herdado da BAT. TODO_VALIDAR: controlador de domínio a usar.
        # Recomenda-se o FQDN (ex.: sspad005.dominio.local).
        Servidor = 'SSPAD005'

        # Como abrir o console "Usuários e Computadores do AD":
        #  'CredencialSalva' = igual à BAT: usa a credencial salva para o
        #                      servidor + sessão IPC$ (validar se funciona
        #                      no ambiente da EVEN).
        #  'OutroUsuario'    = pede usuário/senha do técnico e abre o
        #                      console como esse usuário (recomendado).
        ModoAbertura = 'CredencialSalva'

        PortaLdap = 389
    }

    # -----------------------------------------------------------------
    # Servidores de arquivos (recebem a credencial em "Mapear pastas")
    # Herdados da BAT. TODO_VALIDAR: confirmar se ainda existem.
    # -----------------------------------------------------------------
    ServidoresArquivos = @(
        'SSPFLSSYNC01'
        'SSPFLSSYNC02'
    )

    # -----------------------------------------------------------------
    # Compartilhamentos (pastas de rede)
    #   Id            : identificador interno (letras, números e _)
    #   Nome          : texto mostrado na tela
    #   Caminho       : caminho UNC (\\servidor\compartilhamento\...)
    #   AbrirAoMapear : abre a pasta ao final de "Mapear pastas"
    #   LetraUnidade  : '' = só abre; 'X:' = também mapeia a letra
    #   Perfis        : quem pode abrir pela ferramenta
    #   Habilitado    : $false desativa sem apagar
    # -----------------------------------------------------------------
    Compartilhamentos = @(
        @{
            Id            = 'JURIDICO_IMOBILIARIA'
            Nome          = 'Jurídico - Empreendimentos - Imobiliária'
            # Herdado da BAT. TODO_VALIDAR.
            Caminho       = '\\sspflssync02\Arquivos\Jurídico\JURIDICO IMOBILIARIO\EMPREENDIMENTOS\IMOBILIÁRIA'
            AbrirAoMapear = $true
            LetraUnidade  = ''
            Perfis        = @('Usuario', 'Tecnico', 'Administrador')
            Habilitado    = $true
        }
        @{
            Id            = 'COMERCIAL_IMOBILIARIA'
            Nome          = 'Comercial - Imobiliária'
            # Herdado da BAT. TODO_VALIDAR.
            Caminho       = '\\sspflssync01\Files\Comercial\Imobiliária'
            AbrirAoMapear = $true
            LetraUnidade  = ''
            Perfis        = @('Usuario', 'Tecnico', 'Administrador')
            Habilitado    = $true
        }
    )

    # -----------------------------------------------------------------
    # Impressoras (instalação por porta TCP/IP)
    #   Nome/IP     : herdados da BAT — TODO_VALIDAR
    #   Protocolo   : 'RAW' (porta 9100, padrão do Add-PrinterPort usado
    #                 pela BAT) ou 'LPR'
    #   NomePorta   : mesmo padrão da BAT (IP_<ip>) para reaproveitar
    #                 portas já criadas
    #   Driver      : a BAT usava 'Microsoft IPP Class Driver'.
    #                 TODO_VALIDAR: esse driver gera saída para
    #                 impressoras compatíveis com IPP/PWG/PCLm. Em porta
    #                 RAW 9100 pode imprimir errado ou não imprimir.
    #                 Prefira o driver do fabricante (ex.: PCL6 universal).
    #   DriverInf   : caminho do .inf do driver (instalado via pnputil se
    #                 o driver não existir). '' = não instalar driver.
    #                 O .inf precisa estar em pasta protegida.
    #   Localizacao : texto livre exibido ao usuário
    # -----------------------------------------------------------------
    Impressoras = @(
        @{
            Id = 'PB_BACKOFFICE'; Nome = 'PB - BACKOFFICE'; IP = '192.168.7.34'
            Protocolo = 'RAW'; Porta = 9100; FilaLpr = ''; NomePorta = 'IP_192.168.7.34'
            Driver = 'Microsoft IPP Class Driver'; DriverInf = ''
            Localizacao = 'TODO_VALIDAR'; Habilitada = $true
        }
        @{
            Id = 'COLOR_BACKOFFICE'; Nome = 'COLOR - BACKOFFICE'; IP = '192.168.7.212'
            Protocolo = 'RAW'; Porta = 9100; FilaLpr = ''; NomePorta = 'IP_192.168.7.212'
            Driver = 'Microsoft IPP Class Driver'; DriverInf = ''
            Localizacao = 'TODO_VALIDAR'; Habilitada = $true
        }
        @{
            Id = 'EVEN_MORE'; Nome = 'EVEN MORE'; IP = '192.168.7.80'
            Protocolo = 'RAW'; Porta = 9100; FilaLpr = ''; NomePorta = 'IP_192.168.7.80'
            Driver = 'Microsoft IPP Class Driver'; DriverInf = ''
            Localizacao = 'TODO_VALIDAR'; Habilitada = $true
        }
        @{
            Id = 'EVEN_VENDAS'; Nome = 'EVEN VENDAS'; IP = '192.168.7.33'
            Protocolo = 'RAW'; Porta = 9100; FilaLpr = ''; NomePorta = 'IP_192.168.7.33'
            Driver = 'Microsoft IPP Class Driver'; DriverInf = ''
            Localizacao = 'TODO_VALIDAR'; Habilitada = $true
        }
        @{
            Id = 'PARCERIAS'; Nome = 'PARCERIAS'; IP = '192.168.7.31'
            Protocolo = 'RAW'; Porta = 9100; FilaLpr = ''; NomePorta = 'IP_192.168.7.31'
            Driver = 'Microsoft IPP Class Driver'; DriverInf = ''
            Localizacao = 'TODO_VALIDAR'; Habilitada = $true
        }
    )

    # Instala mesmo se a impressora não responder na rede (útil para
    # preparar máquina fora do escritório). Padrão seguro: $false.
    InstalarImpressoraInacessivel = $false

    # -----------------------------------------------------------------
    # Limpeza de temporários
    # -----------------------------------------------------------------
    Limpeza = @{
        # Só remove arquivos sem alteração há pelo menos N horas.
        # A BAT apagava tudo (equivale a 0). 24 h evita apagar arquivos
        # de instalações/programas em andamento. TODO_VALIDAR.
        IdadeMinimaHoras    = 24
        PermitirTempWindows = $true
        PermitirLixeira     = $true
    }

    # -----------------------------------------------------------------
    # Rede
    # -----------------------------------------------------------------
    Rede = @{
        TimeoutMs = 3000     # timeout de cada teste de conexão
        PortaSmb  = 445
        TimeoutAcessoPastaMs = 8000
    }

    # -----------------------------------------------------------------
    # Logs
    #  %LOCALAPPDATA% = por usuário, sem precisar de permissão especial
    #  (recomendado). Para log central em ProgramData, a pasta precisa
    #  ser criada na instalação com permissão de gravação (ver docs).
    # -----------------------------------------------------------------
    Logs = @{
        Diretorio          = '%LOCALAPPDATA%\EVEN\SuporteTI\Logs'
        RetencaoDias       = 30
        LinhasVisualizacao = 300
    }

    # -----------------------------------------------------------------
    # Recursos: liga/desliga e quem pode usar cada função.
    # Perfis válidos: 'Usuario', 'Tecnico', 'Administrador'.
    # A permissão é conferida de novo no momento da execução.
    # -----------------------------------------------------------------
    Recursos = @{
        CredencialCubo     = @{ Habilitado = $true; Perfis = @('Usuario', 'Tecnico', 'Administrador') }
        MapearPastas       = @{ Habilitado = $true; Perfis = @('Usuario', 'Tecnico', 'Administrador') }
        CredencialAD       = @{ Habilitado = $true; Perfis = @('Tecnico', 'Administrador') }
        LimpezaTemporarios = @{ Habilitado = $true; Perfis = @('Usuario', 'Tecnico', 'Administrador') }
        Impressoras        = @{ Habilitado = $true; Perfis = @('Usuario', 'Tecnico', 'Administrador') }
        AbrirPastas        = @{ Habilitado = $true; Perfis = @('Usuario', 'Tecnico', 'Administrador') }
        AbrirAD            = @{ Habilitado = $true; Perfis = @('Tecnico', 'Administrador') }
        InstalarRSAT       = @{ Habilitado = $true; Perfis = @('Administrador') }
        Diagnostico        = @{ Habilitado = $true; Perfis = @('Tecnico', 'Administrador') }
        VerLogs            = @{ Habilitado = $true; Perfis = @('Tecnico', 'Administrador') }
    }
}
