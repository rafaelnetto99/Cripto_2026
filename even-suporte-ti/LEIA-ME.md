# Central de Suporte TI - EVEN

Modernização da BAT "SUPORTE TI - EVEN" para uma aplicação gráfica em
PowerShell 5.1 + WPF.

> **Material para HOMOLOGAÇÃO.** Não implantar direto em produção. Nenhum
> comando foi executado contra servidores reais. Nenhuma senha real foi
> usada ou incluída.

## Versão simples: um único arquivo BAT

Se você quer só a BAT melhorada (sem instalar nada), use
**`SuporteTI-EVEN.bat`**: dois cliques e pronto, para usuários e para a TI.
Mesmo menu de antes, com senha escondida (`*`), sem senha na linha de
comando, conferência de senha antes de salvar, verificação de cada passo,
limpeza com contagem e confirmação, impressoras com resumo e pedido de
administrador só quando precisa. Servidores, pastas e impressoras ficam no
bloco `CONFIGURACAO` no final do arquivo. Log em
`%LOCALAPPDATA%\EVEN\SuporteTI\suporte.log` (sem senhas).

O restante deste documento descreve a versão completa com interface gráfica.

## Informações que faltam (resumo)

A seção 14 do pedido ("Alterações internas já realizadas") veio só com o
texto de exemplo, sem alterações reais. Por isso **nenhuma mudança foi
inventada**: os valores da BAT foram copiados sem alteração para a
configuração e marcados como não confirmados. O que falta definir:

1. HEX oficial do verde Guatemala (hoje há um valor **provisório**).
2. Domínio: NetBIOS atual (BAT: `EVENSP`), FQDN e sufixos UPN.
3. Grupos do AD de **Técnicos** e **Administradores** (de preferência o SID).
4. Servidor atual do Cubo (BAT: `SSPDW01`) e porta para teste.
5. Controlador de domínio para administração (BAT: `SSPAD005`).
6. Servidores de arquivos (BAT: `SSPFLSSYNC01`, `SSPFLSSYNC02`) e os 2 caminhos.
7. Impressoras: nomes, IPs, protocolo/porta, **driver correto** e localização.
8. Logotipo (arquivo PNG).
9. Se as pastas/impressoras devem continuar sendo feitas por esta ferramenta
   ou por GPO/Intune (recomendado para impressoras).

A lista completa está em [Pontos que precisam de validação da EVEN](#pontos-que-precisam-de-validação-da-even)
e no [Checklist (Etapa 8)](#etapa-8--checklist-de-validação).

## Arquivos

| Arquivo | Função |
|---|---|
| `SuporteTI.ps1` | Aplicação principal (interface WPF, roda **sem** privilégios) |
| `SuporteTI.Elevado.ps1` | Executor de tarefas administrativas pontuais (via UAC) |
| `ui/MainWindow.xaml` | Layout da interface |
| `config/SuporteTI.config.psd1` | **Configuração centralizada** (servidores, IPs, cores, permissões…) |
| `modules/SuporteTI.Core.psm1` | Config, log, validações, perfis, rede com timeout, API Win32 |
| `modules/SuporteTI.Credenciais.psm1` | Gerenciador de Credenciais (sem cmdkey) e validação de senha |
| `modules/SuporteTI.Rede.psm1` | Sessões SMB e abertura de compartilhamentos |
| `modules/SuporteTI.Limpeza.psm1` | Temporários e Lixeira com contagem detalhada |
| `modules/SuporteTI.Impressoras.psm1` | Instalação de impressoras por TCP/IP |
| `modules/SuporteTI.ActiveDirectory.psm1` | RSAT e console do AD |
| `modules/SuporteTI.Acoes.psm1` | Regras de cada função, elevação, diagnóstico, logs |
| `Iniciar-SuporteTI.bat` | Inicializador opcional (sem `ExecutionPolicy Bypass`) |
| `testes/Testar-Validacoes.ps1` | Testes automáticos das validações (não altera nada) |
| `implantacao/Instalar-SuporteTI.ps1` | Instalação em Program Files + atalho (Intune/SCCM/GPO) |
| `implantacao/Desinstalar-SuporteTI.ps1` | Remoção |

---

## Etapa 1 — Entendimento da BAT

Os operadores HTML (`&gt;`, `&amp;`) não apareceram no texto recebido; a BAT
foi lida com `>`, `&` e `|` normais.

| Opção | O que faz | Fluxo |
|---|---|---|
| Menu | Mostra 6 opções e lê a escolha com `set /p` | Opção inválida volta ao menu sem aviso |
| **1 – Credencial Cubo** | Salva usuário/senha para o servidor `SSPDW01` | Lê usuário → remove `@sufixo` e `DOMINIO\` → prefixa `EVENSP\` → lê senha (visível) → `cmdkey /delete` → `cmdkey /add /pass:` → diz "sucesso" sempre |
| **2 – Mapear pastas** | Credencial para 2 servidores de arquivos e abre 2 pastas | Mesmo tratamento de usuário/senha → apaga e cria credencial em `SSPFLSSYNC01` e `SSPFLSSYNC02` → `start` de 2 caminhos UNC → diz "Pastas abertas" sempre |
| **3 – Credencial AD** | Credencial da conta de suporte para `SSPAD005` | Igual à opção 1, com outro servidor |
| **4 – Limpeza** | Apaga `%TEMP%`, `C:\Windows\Temp` e esvazia a Lixeira | `del /f /s /q` (erros ocultos) → `Clear-RecycleBin -Force` (erros ocultos) → diz "concluída" sempre |
| **5 – Impressoras** | Submenu com 5 impressoras + "instalar todas" | Para cada uma, `:ADDPRINTER`: testa se existe (Get-Printer) → cria porta `IP_<ip>` se não existir → `Add-Printer` com "Microsoft IPP Class Driver" → se falhar, copia o IP e abre `control printers` |
| **6 – Abrir AD** | Abre "Usuários e Computadores do AD" em `SSPAD005` | Procura `SSPAD005` no texto do `cmdkey /list` → apaga sessões `net use` → cria sessão `IPC$` → confere se existe `dsa.msc` → `mmc dsa.msc /server=SSPAD005` → diz "aberto" |
| 0 | Sai | `exit` |

As 12 funcionalidades listadas no pedido foram todas preservadas (ver
mapeamento na Etapa 3).

---

## Etapa 2 — Problemas encontrados

Classificação: **Crítico**, **Alto**, **Médio**, **Baixo**.

### Bugs

| # | Problema | Nível |
|---|---|---|
| B1 | **Mensagens de sucesso sem verificação**: "Credencial atualizada com sucesso", "Pastas abertas", "Limpeza concluída" e "Active Directory aberto" aparecem mesmo quando o comando falhou. | Alto |
| B2 | **`set /p` mantém o valor anterior** quando o usuário só aperta Enter: no menu, Enter repete a última opção (ex.: roda a limpeza de novo); no submenu de impressoras repete a última instalação. | Alto |
| B3 | **`cmdkey /delete` antes do `/add`**: se o `/add` falhar (senha com caractere especial, política), o usuário fica **sem** a credencial que funcionava. | Alto |
| B4 | **Detecção de impressora existente não é confiável**: depende do código de saída do `powershell.exe` com `-ErrorAction SilentlyContinue` e pipeline, que não indica de forma confiável se a impressora existe — pode dizer "já existe" sem existir (e pular a instalação) ou o contrário. | Alto |
| B5 | Resultado do `Add-PrinterPort` não é verificado; se a porta falhar, o erro aparece só no `Add-Printer`, com mensagem genérica. Porta criada em tentativa que falhou fica para trás. | Médio |
| B6 | **Pausa duplicada** no fluxo de impressoras: `:ADDPRINTER` faz `pause` e o submenu faz outro `pause`. Em "Instalar todas" há uma pausa por impressora + a final, e o painel de impressoras pode abrir várias vezes (o IP copiado é sobrescrito). | Médio |
| B7 | "Instalar todas" não tem **resumo**: não diz quantas instalaram, quantas falharam nem quais. | Médio |
| B8 | `del /f /s /q` apaga só arquivos: as **subpastas** de `%TEMP%` ficam. Arquivos ocultos/sistema também não são apagados (falta `/a`). | Baixo |
| B9 | Ordem errada no "Abrir AD": autentica no servidor **antes** de verificar se o RSAT existe. Só verifica `dsa.msc` (não a DLL do snap-in) e, se o cmd for 32 bits, `System32` é redirecionado e o arquivo "não existe". | Médio |
| B10 | `net use \\SSPAD005 /delete` não é uma sintaxe útil (não remove a sessão IPC$); erros de todos os `net use` ficam ocultos. | Baixo |
| B11 | Normalização de usuário: `DOMINIO\` vazio gera `EVENSP\`; qualquer domínio digitado é trocado silenciosamente por `EVENSP`; UPN tem o sufixo descartado sem conferir. | Médio |
| B12 | `cmdkey /list \| find "SSPAD005"` encontra **substrings** (ex.: `SSPAD0051`), qualquer tipo de credencial, e depende do texto do cmdkey (idioma). Não confirma que a credencial funciona. | Médio |

### Riscos de segurança

| # | Problema | Nível |
|---|---|---|
| S1 | **Senha visível na digitação** (`set /p`) — qualquer pessoa olhando a tela vê. | Crítico |
| S2 | **Injeção de comandos**: `%usuario%` e `%senha%` são expandidos pelo cmd.exe sem aspas. Uma senha como `abc&calc` executa `calc`; caracteres `&`, `\|`, `<`, `>` em usuário/senha executam ou redirecionam comandos. | Crítico |
| S3 | **Senha na linha de comando** (`cmdkey ... /pass:%senha%`): fica visível em listas de processos, ferramentas de EDR e na auditoria de criação de processos (evento 4688 com linha de comando). | Crítico |
| S4 | **Senha no ambiente do processo**: a variável `senha` continua no cmd.exe até ele fechar (não há `setlocal`) e é **herdada** pelos processos abertos depois (`start` do Explorer, `powershell`, `mmc`). | Alto |
| S5 | Caracteres especiais (`%`, `^`, `!`, `"`) **corrompem a senha** silenciosamente; a credencial salva fica errada e tentativas repetidas podem **bloquear a conta**. | Alto |
| S6 | `powershell -ExecutionPolicy Bypass` com nome/IP interpolados no comando — padrão inseguro (hoje os valores são fixos, mas qualquer edição vira injeção). | Médio |
| S7 | Limpeza sem confirmação, apagando também a Lixeira (irreversível). Não há proteção explícita contra links/junções. | Médio |
| S8 | Funções administrativas (credencial do AD, abrir AD) disponíveis para qualquer usuário. A segurança real é a permissão do AD, mas a ferramenta expõe funções e nomes de servidores. | Médio |
| S9 | Sem log/auditoria: não há registro de quem executou o quê. | Médio |

### Usabilidade

| # | Problema | Nível |
|---|---|---|
| U1 | Opção inválida não gera mensagem. | Baixo |
| U2 | Mensagens técnicas e sem orientação ("Windows não aceitou criar a impressora"). | Médio |
| U3 | Sem progresso; operações longas parecem travadas. | Baixo |
| U4 | `color 0B` e console: pouco acessível, sem foco de teclado, sem ícones. | Baixo |
| U5 | Não informa quando uma função precisa de administrador; o usuário só vê falha. | Médio |

### Dependências

| # | Dependência | Nível |
|---|---|---|
| D1 | Criar porta TCP/IP e instalar driver exigem **administrador** (regras do spooler após PrintNightmare). A BAT não eleva, então falha para usuário comum. | Alto |
| D2 | **Microsoft IPP Class Driver em porta RAW 9100**: esse driver gera saída para impressoras compatíveis com IPP/PWG/PCLm. Em porta RAW pode imprimir lixo ou nada, dependendo do modelo. | Alto |
| D3 | RSAT AD DS (recurso opcional do Windows 10 1809+/11) — precisa de Windows Update/WSUS com "Recursos sob demanda". | Médio |
| D4 | `Clear-RecycleBin` só existe no PowerShell 5.0+. | Baixo |
| D5 | Arquivo BAT precisa estar salvo em UTF-8 (por causa do `chcp 65001` e dos acentos nos caminhos). Salvo em ANSI, os caminhos com "Jurídico/Imobiliária" quebram. | Médio |

### Pontos desatualizados / a validar

| # | Item | Nível |
|---|---|---|
| V1 | Servidores (`SSPDW01`, `SSPFLSSYNC01/02`, `SSPAD005`), domínio `EVENSP`, caminhos e IPs **fixos no código**. A empresa informou que a BAT não acompanhou as mudanças. | Alto |
| V2 | 5 impressoras e seus IPs (`192.168.7.x`) podem ter mudado. | Alto |
| V3 | Os 2 compartilhamentos podem ter sido renomeados/removidos. | Médio |
| V4 | Não se sabe se o "modo credencial salva + IPC$" realmente faz o console do AD usar a conta de suporte no ambiente atual (depende de Kerberos/NTLM e de a máquina estar no domínio). | Médio |

---

## Etapa 3 — Arquitetura proposta

### Tecnologia

- **PowerShell 5.1** (nativo no Windows 10/11, nenhuma instalação extra).
- **WPF + XAML** (nativo no .NET Framework 4.x). WPF atende todos os
  requisitos (PasswordBox, layout adaptável, estilos, DPI), então WinForms
  não foi necessário.
- **API do Windows via P/Invoke** (`Add-Type` com C#, compilado em memória):
  `CredWrite/CredRead` (Gerenciador de Credenciais), `LogonUser` (conferir
  senha), `WNetAddConnection2/WNetCancelConnection2` (SMB),
  `SHEmptyRecycleBin` (Lixeira).
- **Nenhuma dependência externa**, nenhum PowerShell 7.
- BAT apenas como inicializador **opcional**.

### Por que não `cmdkey`

`cmdkey /add /pass:` coloca a senha na linha de comando de outro processo
(S3), passa pelo parser do cmd.exe (S2/S5) e só permite conferir o
resultado pelo texto traduzido do `/list` (B12). A API `CredWrite` cria **o
mesmo tipo de credencial** que o cmdkey (`Domain Password`, persistência
`Enterprise`), mas:

- a senha sai do `PasswordBox` como `SecureString`, vai para memória não
  gerenciada só durante a chamada e é **zerada** logo depois — nunca vira
  texto comum;
- o resultado é um código de erro exato (ex.: 1312 = política proíbe salvar);
- a conferência lê **só o nome do usuário** salvo (`CredRead`), nunca a senha;
- a credencial anterior só é substituída se a nova for gravada (corrige B3).

Limitação (vale também para o cmdkey): se a GPO "Acesso à rede: não
permitir armazenamento de senhas e credenciais para autenticação de rede"
estiver ativa, o Windows recusa salvar — a ferramenta mostra isso
claramente.

### Estrutura de pastas

```
C:\Program Files\EVEN\SuporteTI\        (somente administradores gravam)
├── SuporteTI.ps1                 interface
├── SuporteTI.Elevado.ps1         tarefas administrativas (UAC)
├── Iniciar-SuporteTI.bat         opcional
├── config\SuporteTI.config.psd1  configuração (somente dados)
├── ui\MainWindow.xaml            layout
├── modules\*.psm1                regras
├── assets\logo.png               (a fornecer)
└── testes\Testar-Validacoes.ps1

%LOCALAPPDATA%\EVEN\SuporteTI\
├── Logs\SuporteTI_aaaaMMdd.log   log por usuário (JSON por linha)
└── run\                          troca de resultado com o processo elevado
```

### Separação de responsabilidades

| Camada | Onde | Regra |
|---|---|---|
| Interface | `SuporteTI.ps1` + `MainWindow.xaml` | Só mostra, coleta e confirma. Não executa ações do sistema diretamente. |
| Regras | `modules\SuporteTI.Acoes.psm1` e módulos de domínio | Cada função devolve um objeto de resultado padrão (Status, Mensagem, Itens, Recomendação, Detalhes técnicos, Código de erro, Elevação). |
| Configuração | `config\SuporteTI.config.psd1` | Somente dados, lida com `Import-PowerShellDataFile` (não executa código) e validada ao abrir. |
| Logs | `Write-SuporteLog` (Core) | JSON por linha, mutex contra gravação simultânea, mascaramento de senha, retenção configurável. |

Execução: a interface dispara a ação num **runspace separado** (a janela não
congela), recebe progresso por uma fila thread-safe e trava botões até o fim
(uma operação por vez + uma instância por usuário via mutex).

### Mapeamento das 12 funcionalidades

| BAT | Nova ferramenta |
|---|---|
| 1. Credencial do Cubo | "Atualizar credencial do Cubo" (confere senha no domínio antes de salvar) |
| 2. Credenciais dos servidores de arquivos | "Mapear pastas" |
| 3. Abrir 2 compartilhamentos | "Mapear pastas" (ao final) e "Abrir pastas autorizadas" |
| 4. Credencial do AD | "Configurar credencial administrativa do AD" (TI) |
| 5/6. Temporários + Lixeira | "Limpar arquivos temporários" (3 opções separadas) |
| 7. Validar credencial do AD | "Abrir Active Directory" (`CredRead` exato) |
| 8. Limpar sessões SMB | Automático antes de testar credenciais e antes de abrir o AD |
| 9. Verificar RSAT | "Abrir Active Directory" + "Diagnósticos" |
| 10. AD em servidor específico | `mmc.exe dsa.msc /server=<servidor>` |
| 11. Impressoras individual/lote | "Mapear impressoras" (caixas de seleção + "Selecionar todas") |
| 12. Painel de impressoras como alternativa | Aberto **uma vez** ao final, com o IP da primeira falha copiado |

Novas: "Diagnósticos administrativos", "Visualizar logs técnicos",
"Instalar RSAT" (administrador).

### Modelo de permissões

| Perfil | Como é identificado | Acesso padrão |
|---|---|---|
| **Usuário final** | Padrão (inclusive quando grupos não estão configurados ou o domínio está fora) | Cubo, Mapear pastas, Limpeza, Impressoras, Abrir pastas |
| **Técnico de TI** | Membro do grupo do AD em `Perfis.GrupoTecnicos` | + Credencial do AD, Abrir AD, Diagnósticos, Logs |
| **Administrador** | Membro do grupo em `Perfis.GrupoAdministradores` | + Instalar RSAT |

- O perfil vem dos **grupos do token de logon** (SIDs) — funciona fora da
  rede e não depende de consulta ao AD. Se só o **nome** do grupo for
  configurado e não puder ser resolvido, o perfil cai para **Usuário**
  (falha segura). Recomenda-se configurar o **SID**.
- A permissão é verificada **três vezes**: ao montar o menu (esconde o
  cartão), ao clicar (interface) e **dentro do runspace na hora de executar**
  (perfil recalculado).
- **Perfil ≠ privilégio.** Perfil só libera funções. Privilégio de
  administrador local é pedido **por ação**, via UAC, num processo separado
  (`SuporteTI.Elevado.ps1`) que aceita apenas 3 ações fixas
  (`LimparTempWindows`, `InstalarImpressoras`, `InstalarRSAT`) e Ids
  validados. A interface nunca roda elevada.
- O limite de segurança real continua sendo o Windows/AD (ACLs, UAC). A
  ferramenta é uma camada de conveniência e não substitui essas permissões.
- O técnico que atende na máquina de um usuário pode: (a) abrir a
  ferramenta "como outro usuário" (Shift + botão direito no atalho) com a
  conta de TI, ou (b) usar o modo `ServidorAD.ModoAbertura = 'OutroUsuario'`,
  que pede usuário/senha e abre só o console do AD com essa conta.

### Logs: LocalAppData × ProgramData

Padrão: `%LOCALAPPDATA%\EVEN\SuporteTI\Logs`. Motivo: a aplicação roda sem
privilégios; o usuário sempre pode gravar ali e não lê logs de outros
usuários. Para log central em `ProgramData`, a pasta precisa ser criada na
instalação com permissão de **criar arquivos/acrescentar dados** para
Usuários — e, mesmo assim, um usuário poderia alterar o log de outro.
Para auditoria centralizada de verdade, recomenda-se coletar os arquivos
por agente (Intune/SIEM). Se a pasta configurada não for gravável, a
ferramenta usa `%TEMP%\EVEN-SuporteTI\Logs`.

### Implantação e atualização (resumo)

- Instalar em `C:\Program Files\EVEN\SuporteTI` (pasta protegida) por
  Intune/SCCM/GPO; atalho no Menu Iniciar.
- Scripts **assinados** com certificado de assinatura de código da CA
  interna; política `AllSigned` (ou `RemoteSigned`) por GPO/Intune.
- Atualizar servidores/impressoras = trocar **só** o `config\*.psd1` (pela
  mesma ferramenta de implantação). Atualizar código = nova versão assinada.
- Detalhes na Etapa 6.

---

## Etapa 4 — Protótipo textual

### Tela principal

```
┌──────────────────────────────────────────────────────────────────────────┐
│ [LOGO]  Central de Suporte TI - EVEN                     (👤 Usuário)   │ ← preto
│         Ferramentas de suporte para o seu computador                     │
├══════════════════════════════════════════════════════════════════════════┤ ← faixa verde
│ ⌂ Início            │ ⚠ Modo homologação: ... (só para TI)              │
│ 🔑 Acesso e         │                                                    │
│    credenciais      │ Início                                             │
│ 🔧 Ferramentas do   │ Escolha uma função...                              │
│    usuário          │                                                    │
│ 🛡 Ferramentas do TI│ Acesso e credenciais                               │
│   (só para TI)      │ ┌────────────┐ ┌────────────┐ ┌────────────┐       │
│                     │ │ 🔑         │ │ 📁         │ │ 🔒 (TI)    │       │
│     ← preto         │ │ Atualizar  │ │ Mapear     │ │ Credencial │       │
│                     │ │ credencial │ │ pastas     │ │ do AD      │       │
│                     │ │ do Cubo    │ │ ...        │ │ ...        │       │
│                     │ └────────────┘ └────────────┘ └────────────┘       │
│                     │ Ferramentas do usuário                             │
│                     │ [🗑 Limpar temporários] [🖨 Impressoras] [📂 Pastas]│
├──────────────────────────────────────────────────────────────────────────┤
│ ✔ Pronto. Escolha uma função.                    [barra de progresso]    │ ← cinza-claro
│ ▸ Atividades desta sessão (expansível)                                   │
├──────────────────────────────────────────────────────────────────────────┤
│ Versão 1.0.0 • Computador: PC01 • Usuário: EVENSP\joao • Perfil: Usuário │ ← preto
│                                                          ● Pronto        │
└──────────────────────────────────────────────────────────────────────────┘
```

- Cartões mostram ícone, título, descrição e, quando aplicável, o selo
  "🛡 Pode exigir permissão especial".
- Layout com `WrapPanel` e rolagem: os cartões se reorganizam em telas
  menores/escala 125–150%. Janela mínima 820×580.
- Navegação por teclado: Tab, Enter executa, **Esc volta ao menu**; foco
  visível em todos os botões.

### Tela de ação (exemplo: Atualizar credencial do Cubo)

```
[← Voltar ao menu]

🔑  Atualizar credencial do Cubo
    Salva com segurança seu usuário e senha de rede para acessar o Cubo...
    [🛡 Não exige administrador]

    Usuário de rede
    [ joao.silva                     ]
    Exemplo: joao.silva (o domínio EVENSP é adicionado automaticamente).
    Senha
    [ ●●●●●●●●                       ]
    ⚠ Caps Lock está ativado.            (só quando ativo)
    A senha não é exibida, não é gravada em arquivo e não vai para o log...

    [ ▶ Salvar credencial ]

┌ ✔ Concluído com sucesso ───────────────────────────────────────┐
│ Credencial do Cubo atualizada.                                 │
│ ✔ Usuário e senha conferidos no domínio.                       │
│ ✔ SSPDW01: credencial salva.                                   │
│ 💡 Feche e abra novamente o Excel/relatório que usa o Cubo.    │
│ [⧉ Copiar detalhes técnicos]                                   │
└────────────────────────────────────────────────────────────────┘
```

Fluxo de toda ação:

1. Explicação curta + selo informando se exige administrador.
2. Validação local (usuário normalizado e exibido como `EVENSP\usuario`,
   senha não vazia, ao menos uma opção marcada).
3. Confirmação (Sim/Não, padrão **Não**) para ações que substituem ou apagam.
4. Botões, menu e campos desabilitados; barra de progresso + texto no status.
5. Resultado com **ícone + título + cor**: ✔ Sucesso / ⚠ Concluído com
   observações / ⚠ Concluído parcialmente / ✖ Não foi possível concluir /
   ⛔ Acesso negado / Cancelado.
6. Itens detalhados, ação recomendada e "Copiar detalhes técnicos"
   (sem senha).
7. Registro no log. Botão "Voltar ao menu" (ou Esc) sem fechar a aplicação.

### Telas específicas

- **Mapear pastas**: usuário/senha → confere senha → salva credencial em
  cada servidor de arquivos → encerra sessões antigas → testa acesso (IPC$)
  → abre as pastas configuradas. Itens por servidor e por pasta.
- **Limpar temporários**: caixas "Temporários do usuário" (marcada),
  "Temporários do Windows (exige administrador)" (desmarcada), "Esvaziar a
  Lixeira" (marcada). Confirmação lista o que será limpo. Resultado separado:
  > ✔ Temporários do usuário: 1.240 arquivo(s) removido(s) (380,2 MB); 12 pasta(s) vazia(s) removida(s); 8 em uso (ignorados); 0 sem permissão; 35 recente(s) preservado(s).
  > ⚠ Temporários do Windows: não executado por falta de permissão de administrador.
  > ✔ Lixeira: 57 item(ns) removido(s) (1,1 GB).
- **Mapear impressoras**: lista com caixas + "Selecionar todas". Usuário vê
  nome e local; TI vê também IP e driver. Resultado por impressora
  (instalada / já estava instalada / não respondeu / falhou) e resumo
  "3 impressora(s) pronta(s) e 2 com problema". Se alguma falhar, abre o
  painel de impressoras **uma vez** e copia o IP da primeira falha.
- **Abrir pastas autorizadas**: lista das pastas liberadas ao perfil,
  todas marcadas.
- **Abrir Active Directory** (TI): verifica RSAT → testa LDAP → confere
  credencial salva → renova sessão → abre console. Botão secundário
  "Instalar RSAT (administrador)" visível só para Administrador.
- **Diagnósticos** (TI): texto com ambiente, perfil e motivo, pasta
  protegida, spooler, RSAT, credenciais (só existe/não existe),
  conectividade de cada servidor/impressora com tempo de resposta e lista
  de valores `TODO_VALIDAR`.
- **Logs** (TI): últimas N linhas do log, mais recentes primeiro, e botão
  "Abrir pasta de logs".

### Mensagens (exemplos)

| Situação | Mensagem ao usuário | Ação recomendada |
|---|---|---|
| Senha errada | ✖ Usuário ou senha incorretos. | Confira usuário e senha (Caps Lock?). Após várias tentativas a conta pode ser bloqueada. |
| Fora da rede | ⚠ Não foi possível conferir a senha agora: Nenhum servidor do domínio respondeu. | Conecte-se à rede ou VPN. |
| Conta bloqueada | ✖ A conta está bloqueada. Procure a TI. | — |
| UAC cancelado | A permissão de administrador não foi concedida. | Esta parte precisa de um técnico de TI. |
| Config pendente | Esta função ainda não foi configurada pela equipe de TI. | Avise a TI. (Configuração pendente: TODO_VALIDAR) |
| Erro inesperado | Ocorreu um erro inesperado e a operação não foi concluída. | Copie os detalhes técnicos e envie para a TI. |

---

## Etapa 5 — Código completo

Todos os arquivos estão nesta pasta, completos (sem trechos omitidos):

- [`config/SuporteTI.config.psd1`](config/SuporteTI.config.psd1)
- [`SuporteTI.ps1`](SuporteTI.ps1)
- [`ui/MainWindow.xaml`](ui/MainWindow.xaml)
- [`SuporteTI.Elevado.ps1`](SuporteTI.Elevado.ps1)
- [`modules/SuporteTI.Core.psm1`](modules/SuporteTI.Core.psm1)
- [`modules/SuporteTI.Credenciais.psm1`](modules/SuporteTI.Credenciais.psm1)
- [`modules/SuporteTI.Rede.psm1`](modules/SuporteTI.Rede.psm1)
- [`modules/SuporteTI.Limpeza.psm1`](modules/SuporteTI.Limpeza.psm1)
- [`modules/SuporteTI.Impressoras.psm1`](modules/SuporteTI.Impressoras.psm1)
- [`modules/SuporteTI.ActiveDirectory.psm1`](modules/SuporteTI.ActiveDirectory.psm1)
- [`modules/SuporteTI.Acoes.psm1`](modules/SuporteTI.Acoes.psm1)
- [`Iniciar-SuporteTI.bat`](Iniciar-SuporteTI.bat)
- [`testes/Testar-Validacoes.ps1`](testes/Testar-Validacoes.ps1)
- [`implantacao/Instalar-SuporteTI.ps1`](implantacao/Instalar-SuporteTI.ps1)
- [`implantacao/Desinstalar-SuporteTI.ps1`](implantacao/Desinstalar-SuporteTI.ps1)

Os arquivos `.ps1`, `.psm1` e `.psd1` estão em **UTF-8 com BOM** (necessário
para os acentos no PowerShell 5.1). Ao editar, mantenha essa codificação
(no Bloco de Notas: "Salvar como" → "UTF-8 com BOM").

### Decisões importantes no código

- **Correções da limpeza**: só apaga dentro de `GetTempPath()` e
  `%SystemRoot%\Temp`; recusa raiz de unidade, `%SystemRoot%` e o perfil;
  nunca segue links/junções; percurso iterativo; arquivos com menos de
  `IdadeMinimaHoras` (padrão 24 h) são preservados; conta removidos, em uso,
  sem permissão, recentes e links; Temp do Windows só elevado.
- **Lixeira**: `SHEmptyRecycleBin` (API do Shell) em vez de
  `Clear-RecycleBin` — funciona em qualquer PowerShell, sem caixa de
  diálogo, e conta itens antes/depois.
- **Impressoras**: existência por objeto (`Get-Printer` + nome exato, sem
  curingas), conferência do spooler, teste de rede com timeout antes de
  pedir UAC, porta existente só é reaproveitada se apontar para o mesmo IP,
  driver conferido (e instalável por `.inf` em pasta protegida), conferência
  final de nome/porta/driver, remoção da porta criada se a instalação falhar.
- **AD**: RSAT verificado antes de conectar (`dsa.msc` + `dsadmin.dll`,
  usando `Sysnative` quando o PowerShell for 32 bits); credencial conferida
  por `CredRead` exato; sessão IPC$ por API com código de erro real;
  `mmc.exe "dsa.msc" /server=<servidor>`.
- **Rede**: `TcpClient.ConnectAsync` + `Wait(timeout)` (o
  `Test-NetConnection` não tem timeout); acesso a pasta UNC testado num
  runspace com timeout.
- **Processo elevado**: grava o resultado com `FileMode.CreateNew` num
  arquivo de nome aleatório, recusando pasta que seja link — evita que um
  usuário use o processo elevado para sobrescrever arquivos do sistema.

---

## Etapa 6 — Instruções de implantação

### 1. Onde colocar cada arquivo

| Arquivo | Destino |
|---|---|
| Toda a pasta | `C:\Program Files\EVEN\SuporteTI\` |
| Logotipo | `C:\Program Files\EVEN\SuporteTI\assets\logo.png` e `Visual.CaminhoLogotipo = 'assets\logo.png'` |
| Atalho | Menu Iniciar (todos os usuários): `%ProgramData%\Microsoft\Windows\Start Menu\Programs\EVEN\Central de Suporte TI.lnk` |

Destino do atalho:

```
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -File "C:\Program Files\EVEN\SuporteTI\SuporteTI.ps1"
```

Criação do atalho (rodar como administrador no script de instalação):

```powershell
$pasta = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\EVEN'
New-Item -ItemType Directory -Path $pasta -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path $pasta 'Central de Suporte TI.lnk'))
$lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = '-NoProfile -NoLogo -STA -WindowStyle Hidden -File "C:\Program Files\EVEN\SuporteTI\SuporteTI.ps1"'
$lnk.WorkingDirectory = 'C:\Program Files\EVEN\SuporteTI'
$lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,109"
$lnk.Save()
```

### 2. Homologação

1. Preencher a configuração (Etapa 8) num computador de teste, fora da
   produção, com um usuário de teste.
2. Rodar `testes\Testar-Validacoes.ps1` — deve terminar com "Todos os
   testes passaram".
3. Durante a homologação, se a ferramenta precisar rodar fora de Program
   Files, adicione a pasta em `Aplicacao.PastasConfiaveis` **somente na
   máquina de teste** e garanta que usuários comuns não podem gravar nela.
4. Para testar funções de TI antes de configurar os grupos, é possível usar
   `Perfis.ConsiderarAdminLocalElevadoComoTecnico = $true` **apenas em
   homologação**.
5. Executar o plano de testes (Etapa 7) e conferir os logs em
   `%LOCALAPPDATA%\EVEN\SuporteTI\Logs`.

### 3. Como executar

- Pelo atalho do Menu Iniciar, ou
- `Iniciar-SuporteTI.bat`, ou
- `powershell.exe -NoProfile -STA -File "C:\Program Files\EVEN\SuporteTI\SuporteTI.ps1"`

### 4. Assinatura de código (no lugar de `ExecutionPolicy Bypass`)

O Windows cliente vem com a política `Restricted` (nenhum script roda).
**Não** use `Bypass`: ele desativa a proteção para tudo que o processo
executar. Use assinatura + política por GPO:

1. Emitir um certificado **Code Signing** na CA interna (modelo "Assinatura
   de código") para a equipe de TI; guardar a chave privada protegida.
2. Assinar (todos os `.ps1` e `.psm1`):

   ```powershell
   $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
   Get-ChildItem 'C:\Build\SuporteTI' -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
       Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert `
           -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
   }
   Get-ChildItem 'C:\Build\SuporteTI' -Recurse -Include *.ps1, *.psm1 | Get-AuthenticodeSignature |
       Format-Table Path, Status
   ```

   (Use o servidor de carimbo de tempo aprovado pela EVEN — TODO_VALIDAR.)
3. Distribuir o certificado da CA raiz (já existe em domínio) e o
   certificado do assinante em **Editores Confiáveis** (GPO: Configuração do
   Computador › Políticas › Configurações do Windows › Configurações de
   Segurança › Políticas de Chave Pública).
4. GPO "Ativar execução de scripts" = **Permitir somente scripts assinados**
   (AllSigned) ou **Permitir scripts locais e scripts assinados remotos**
   (RemoteSigned).
5. Qualquer edição em `.ps1`/`.psm1` invalida a assinatura — é o objetivo.
   O `.psd1` e o `.xaml` não são verificados pela política; por isso **a
   pasta precisa ser protegida** (só administradores gravam).

### 5. Distribuição

- **Intune (recomendado)**: empacotar a pasta com `IntuneWinAppUtil.exe`
  como Win32 app. Instalação (contexto Sistema):
  `powershell.exe -NoProfile -File implantacao\Instalar-SuporteTI.ps1`
  (copia para `C:\Program Files\EVEN\SuporteTI`, cria o atalho e grava a
  versão em `HKLM\SOFTWARE\EVEN\SuporteTI`). Desinstalação:
  `implantacao\Desinstalar-SuporteTI.ps1`. Regra de detecção: valor
  `Versao` nessa chave de registro. Política de execução: Intune › Configuração › Catálogo de
  configurações › "Turn on Script Execution".
- **SCCM/MECM**: Application com o mesmo script de instalação; detecção pela
  versão; implantação para coleção de dispositivos.
- **GPO**: Preferências › Arquivos (copiar de `\\servidor\NETLOGON\...` ou
  compartilhamento somente leitura para `C:\Program Files\EVEN\SuporteTI`)
  + Preferências › Atalhos.
- **Compartilhamento interno** (só homologação): pasta somente leitura para
  usuários. Executar direto de UNC exige que a pasta esteja em
  `PastasConfiaveis` para ações elevadas e que os scripts estejam assinados.

### 6. Atualizar configurações sem alterar código

Editar só `config\SuporteTI.config.psd1` (em UTF-8 com BOM) e redistribuir
o arquivo pela mesma ferramenta. Exemplos:

- Trocar servidor do Cubo: `Cubo.Servidor`.
- Nova impressora: copiar um bloco em `Impressoras`, com `Id` novo.
- Desativar função obsoleta: `Recursos.<Função>.Habilitado = $false` (o
  código continua no lugar).
- Desativar um compartilhamento/impressora: `Habilitado`/`Habilitada = $false`.

Ao abrir, a ferramenta valida a configuração; se houver erro de formato,
mostra exatamente qual chave está errada e não abre.

### 7. O que exige administrador

| Recurso | Exige |
|---|---|
| Instalar a ferramenta em Program Files | Administrador (implantação) |
| Limpar temporários do Windows | Administrador local (UAC na hora) |
| Instalar impressora (porta TCP/IP, driver) | Administrador local (UAC na hora) |
| Instalar RSAT | Administrador local + perfil Administrador |
| Credenciais, pastas, Lixeira, temporários do usuário, abrir AD, diagnóstico, logs | Não (abrir AD exige conta de suporte no domínio) |

### 8. Desinstalar / reverter

1. Rodar `implantacao\Desinstalar-SuporteTI.ps1` como administrador/Sistema
   (remove a pasta `C:\Program Files\EVEN\SuporteTI`, o atalho e a chave
   de registro).
2. Opcional, por usuário: apagar `%LOCALAPPDATA%\EVEN\SuporteTI`.
3. Credenciais salvas continuam no Gerenciador de Credenciais (como na BAT).
   Para remover: Painel de Controle › Gerenciador de Credenciais ›
   Credenciais do Windows, ou `cmdkey /delete:<servidor>`.
4. Impressoras instaladas continuam. Para remover:
   `Remove-Printer -Name '<nome>'` e `Remove-PrinterPort -Name 'IP_<ip>'`.
5. Reverter para a BAT antiga é possível a qualquer momento (as duas não
   conflitam), mas não é recomendado pelos riscos da Etapa 2.

---

## Etapa 7 — Plano de testes

Pré-requisitos: máquina de homologação Windows 10 22H2 e Windows 11,
configuração preenchida, um usuário comum, um técnico e um administrador de
teste. Após cada teste, conferir a linha no log (sem senha).

| # | Cenário | Passos | Resultado esperado |
|---|---|---|---|
| T01 | **Usuário comum** | Abrir a ferramenta | Perfil "Usuário"; menu "Ferramentas do TI" e cartão "Credencial do AD" não aparecem; sem aviso de homologação |
| T02 | Usuário comum força função de TI | Como usuário comum, num console PowerShell: importar os módulos, rodar `Initialize-SuporteContexto` e chamar `Invoke-AcaoSuporte -Id AbrirAD` (contornando a interface) | Resultado "Acesso negado" e log `Negado` — a permissão é checada na execução, não só na tela |
| T03 | **Técnico de TI** | Logar com membro do grupo de técnicos | Perfil "Técnico de TI"; vê Credencial do AD, Abrir AD, Diagnósticos, Logs; **não** vê "Instalar RSAT" |
| T04 | **Administrador** | Logar com membro do grupo de admins | Vê tudo, inclusive "Instalar RSAT" |
| T05 | Grupo configurado só por nome, fora do domínio | Configurar só `Nome`, desconectar rede, abrir | Perfil cai para Usuário (falha segura); diagnóstico mostra o motivo |
| T06 | **Computador fora da rede** | Cabo/Wi-Fi desligados → Cubo, Mapear pastas, Impressoras, Abrir AD | Cubo: aviso "não foi possível conferir a senha" e credencial salva (se permitido); Pastas: "servidor inacessível"; Impressoras: "não respondeu na rede" sem pedir UAC; AD: "servidor não respondeu". Nenhuma tela travada > timeout |
| T07 | **Sem VPN** (rede doméstica) | Igual a T06 | Mesmos resultados, mensagens citando VPN |
| T08 | **Servidor indisponível** | Apontar `Cubo.Servidor`/servidor de arquivos para nome inexistente (em homologação) | "Nome não encontrado no DNS"/"timeout" nos detalhes; status Aviso/Falha |
| T09 | **Credencial incorreta** | Senha errada no Cubo | ✖ "Usuário ou senha incorretos", nada salvo, credencial anterior preservada, código 1326 no log |
| T10 | Conta bloqueada / senha expirada | Usar conta de teste bloqueada/expirada | Mensagens 1909 / 1330 |
| T11 | **RSAT ausente** | Máquina sem RSAT → Abrir AD | "Console do AD (RSAT) não está instalado", sem tentar conectar; Admin: botão Instalar RSAT funciona com UAC |
| T12 | **Impressora já instalada** | Instalar uma impressora duas vezes | Segunda vez: "já estava instalada", sem UAC |
| T13 | Mesmo nome, porta diferente | Criar manualmente impressora com mesmo nome e outra porta | Aviso "já existe com outra porta", nada alterado |
| T14 | **Driver ausente** | Configurar driver inexistente sem `DriverInf` | "driver não disponível", porta criada é removida, painel de impressoras abre uma vez com IP copiado |
| T15 | **Falta de permissão** (UAC negado) | Usuário comum → Impressoras / Temp do Windows → cancelar UAC | Impressoras: "não instalada — exige administrador"; Limpeza: "Temporários do Windows: não executado por falta de permissão", resto executado (status Parcial) |
| T16 | Ferramenta fora de pasta protegida | Rodar de `C:\Temp` sem `PastasConfiaveis` | Ações elevadas recusadas antes do UAC com explicação |
| T17 | **Caminho de rede indisponível** | Configurar compartilhamento inexistente | "pasta não encontrada ou sem permissão"; demais pastas abrem (Parcial) |
| T18 | **Caracteres especiais no usuário** | Usuário: `  "joao.silva" `, `EVENSP\joao.silva`, `joao.silva@empresa`, `OUTRO\joao`, `jo|ao`, `joao.` | Normaliza os 3 primeiros; recusa os 3 últimos com mensagem clara |
| T19 | **Caracteres especiais na senha** | Senha de teste com `& % ^ ! " ' < > \| espaço ç é` | Credencial salva e aceita pelo servidor; nenhum comando executado; log sem a senha |
| T20 | Senha nunca vazada | Após T09/T19: procurar a senha nos logs, na área de transferência ("Copiar detalhes") e na linha de comando dos processos (Gerenciador de Tarefas › coluna Linha de comando) | Não aparece em lugar nenhum |
| T21 | **Execução repetida** | Clicar várias vezes no botão; abrir a ferramenta duas vezes | Botões desabilitados durante a execução; segunda instância avisa "já está aberta" |
| T22 | Fechar durante execução | Fechar a janela durante a limpeza | Aviso "operação em andamento", janela não fecha |
| T23 | **Falha parcial em "Instalar todas"** | 5 impressoras, sendo 1 desligada e 1 com driver ausente | 3 OK/já existentes, 1 "não respondeu", 1 "falhou"; status "Concluído parcialmente"; painel aberto uma única vez |
| T24 | Limpeza com arquivos em uso | Abrir Word/Excel e limpar | Arquivos em uso contados como ignorados; status Sucesso |
| T25 | Limpeza não sai da pasta | Criar junção em `%TEMP%` apontando para uma pasta de teste com arquivos | Junção contada como "link ignorado"; pasta de destino intacta |
| T26 | Lixeira vazia / cheia | Executar com a Lixeira vazia e com itens | "já estava vazia" / "N item(ns) removido(s)" |
| T27 | Configuração inválida | Colocar IP `999.1.1.1` ou cor `verde` | Ferramenta não abre e mostra a chave com erro |
| T28 | Valor TODO_VALIDAR | Deixar `Cubo.Servidor = 'TODO_VALIDAR'` | Função mostra "ainda não foi configurada pela TI" |
| T29 | DPI/resolução | 1366×768 a 100%, 1920×1080 a 150%, 4K a 200% | Cartões se reorganizam, sem cortes; rolagem disponível |
| T30 | Acessibilidade | Navegar só com teclado; Narrador | Foco visível; Esc volta; estados com texto e ícone |
| T31 | Script adulterado | Alterar uma linha de um `.psm1` assinado | PowerShell recusa carregar (AllSigned) |
| T32 | Testes automáticos | `testes\Testar-Validacoes.ps1` | "Todos os testes passaram" |

---

## Etapa 8 — Checklist de validação

Antes de produção, a TI da EVEN precisa confirmar:

- [ ] HEX oficial do **verde Guatemala** (`Visual.CorPrimaria` e `CorPrimariaEscura`).
- [ ] Arquivo de **logotipo** e `Visual.CaminhoLogotipo`.
- [ ] **Domínio**: NetBIOS (`EVENSP`?), FQDN e sufixos UPN.
- [ ] Se o prefixo do UPN é sempre igual ao sAMAccountName.
- [ ] **SID** (ou nome) dos grupos de **Técnicos** e **Administradores**.
- [ ] Servidor atual do **Cubo** (`SSPDW01`?) e porta para teste.
- [ ] Tipo de credencial que o Cubo usa (credencial de domínio para o nome do
      servidor, como na BAT? HTTP/msmdpump?).
- [ ] **Controlador de domínio** para administração (`SSPAD005`?) e FQDN.
- [ ] Modo de abertura do AD: `CredencialSalva` (como a BAT) funciona? Ou
      adotar `OutroUsuario`?
- [ ] **Servidores de arquivos** (`SSPFLSSYNC01/02`?) — ainda existem?
- [ ] Os **2 caminhos** de compartilhamento (acentos/nomes exatos) e quais
      perfis podem abrir cada um.
- [ ] Se deve mapear **letra de unidade** para algum compartilhamento.
- [ ] Lista de **impressoras**: nome, IP, protocolo (RAW/LPR), porta, local.
- [ ] **Driver** de cada impressora (o IPP Class Driver em porta RAW é
      compatível?) e, se necessário, `.inf` em pasta protegida.
- [ ] Se impressoras serão distribuídas por **GPO/Intune/servidor de
      impressão** (recomendado) em vez desta ferramenta.
- [ ] Política "não permitir armazenamento de credenciais de rede" está
      desativada? (senão nenhuma credencial é salva, nem pela BAT).
- [ ] `Limpeza.IdadeMinimaHoras` (24 h proposto; BAT = 0).
- [ ] Se usuários finais devem ver a opção "Temporários do Windows".
- [ ] Pasta de **logs** e retenção; necessidade de coleta central.
- [ ] Certificado de **assinatura de código**, servidor de carimbo de tempo
      e GPO de política de execução.
- [ ] Ferramenta de **distribuição** (Intune/SCCM/GPO) e pasta de instalação.
- [ ] Executar todo o **plano de testes** em Windows 10 e 11.
- [ ] Depois de tudo confirmado: `Aplicacao.ValoresConfirmadosPelaTI = $true`
      e versão sem `-homologacao`.

---

## Pontos que precisam de validação da EVEN

Todos os valores abaixo estão em `config\SuporteTI.config.psd1`. Os marcados
"herdado da BAT" foram copiados **sem alteração** e **não** foram
confirmados como atuais. Os `TODO_VALIDAR` bloqueiam a função que depende
deles até serem preenchidos. O "Diagnósticos administrativos" lista todos
os pendentes.

| Chave | Valor atual | Situação |
|---|---|---|
| `Visual.CorPrimaria` / `CorPrimariaEscura` | `#0B6E4F` / `#084F39` | **PROVISÓRIO** — não é o HEX oficial |
| `Visual.CaminhoLogotipo` | `TODO_VALIDAR` | Falta o arquivo |
| `Dominio.NetBIOS` | `EVENSP` | Herdado da BAT |
| `Dominio.FQDN` | `TODO_VALIDAR` | Não informado |
| `Dominio.SufixosUPN` | `TODO_VALIDAR` | Não informado (enquanto pendente, aceita qualquer sufixo, como a BAT) |
| `Perfis.GrupoTecnicos` | `TODO_VALIDAR` | Sem ele, ninguém é Técnico |
| `Perfis.GrupoAdministradores` | `TODO_VALIDAR` | Sem ele, ninguém é Administrador |
| `Cubo.Servidor` | `SSPDW01` | Herdado da BAT |
| `Cubo.PortaTeste` | `0` (sem teste) | Definir porta |
| `ServidorAD.Servidor` | `SSPAD005` | Herdado da BAT |
| `ServidorAD.ModoAbertura` | `CredencialSalva` | Validar se funciona |
| `ServidoresArquivos` | `SSPFLSSYNC01`, `SSPFLSSYNC02` | Herdados da BAT |
| `Compartilhamentos[0].Caminho` | `\\sspflssync02\Arquivos\Jurídico\JURIDICO IMOBILIARIO\EMPREENDIMENTOS\IMOBILIÁRIA` | Herdado da BAT |
| `Compartilhamentos[1].Caminho` | `\\sspflssync01\Files\Comercial\Imobiliária` | Herdado da BAT |
| `Impressoras` (5) | PB - BACKOFFICE `192.168.7.34`; COLOR - BACKOFFICE `192.168.7.212`; EVEN MORE `192.168.7.80`; EVEN VENDAS `192.168.7.33`; PARCERIAS `192.168.7.31` | Herdados da BAT |
| `Impressoras[*].Driver` | `Microsoft IPP Class Driver` | Herdado da BAT — compatibilidade a validar |
| `Impressoras[*].Localizacao` | `TODO_VALIDAR` | Não informado |
| `Limpeza.IdadeMinimaHoras` | `24` | Proposta nova (BAT apagava tudo) |

### Limitações conhecidas

- Mudança de grupo no AD só altera o perfil após novo logon (token).
- O perfil é uma camada de conveniência; a segurança real são as
  permissões do AD e o UAC.
- Validar a senha no domínio conta como tentativa para bloqueio de conta
  (pode ser desativado em `Dominio.ValidarSenhaNoDominio`).
- Se houver unidade com letra já mapeada para um servidor com outro usuário,
  o Windows pode manter a sessão antiga (erro 1219) até o logoff — a
  ferramenta avisa.
- A interface não foi executada em Windows durante esta preparação: a
  sintaxe de todos os scripts foi verificada pelo parser do PowerShell e as
  validações passaram nos testes automáticos, mas a interface WPF e as
  chamadas ao Windows precisam do plano de testes da Etapa 7.
