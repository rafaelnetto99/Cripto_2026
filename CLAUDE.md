# Contexto do projeto — plataforma de aluguel de hashrate

## O que é

Plataforma no estilo rentalhash.com: donos de ASICs SHA-256 apontam as
máquinas para o nosso servidor stratum e recebem um valor fixo em USD por
TH/s entregue, creditado por hora fechada. Nós repassamos o hashrate para
uma pool upstream (FPPS, paga em BTC). A margem do negócio é a diferença
entre o que a pool paga e a taxa fixa prometida ao cliente.

Marca, textos e visual serão próprios (não copiar logo/conteúdo do
rentalhash.com).

## Fase atual: teste

O dono está validando a ideia com as próprias máquinas antes de investir
mais. Prioridade: fazer o proxy medir certo e comparar com a pool.

- Questões regulatórias/jurídicas foram conscientemente adiadas para
  depois do teste. Não bloquear trabalho por isso.
- A definição da taxa (USD por TH/s/dia) fica com o dono; ajudar com
  cálculos e ferramentas quando pedido.
- Pool upstream ainda não definida.

## Arquitetura (planejada)

1. Proxy stratum — FEITO (este repositório)
2. Medição de shares por minuto — FEITO
3. Ledger em USD, crédito por hora — FEITO
4. API de leitura — FEITO (básica)
5. Painel web (Next.js): cadastro/login com 2FA, máquinas, extrato,
   saques, indicação, fidelidade — A FAZER
6. Saques em USDT (TRC20, ERC20, Polygon, BEP20) e BTC, fila com
   aprovação manual, mínimo US$ 10 — A FAZER
7. Área admin: taxa, aprovação de saques, margem pool vs. creditado — A FAZER
8. Landing page com calculadora — A FAZER
9. Fidelidade (até +10% por estabilidade) e indicação (1%) — A FAZER

## Como o código atual funciona

- Go 1.22, só dependência `github.com/lib/pq`. Postgres (schema em
  `schema.sql`). Docker Compose para subir.
- `proxy.go`: uma conexão com a pool por máquina. Repassa tudo, exceto
  `mining.authorize` (valida nick em `users`, reescreve para
  `POOL_USER.nick_worker`) e `mining.submit` (reescreve o worker).
  Bloqueia `client.reconnect` da pool.
- `recorder.go`: soma a dificuldade dos shares aceitos por
  (nick, worker, minuto) em memória e grava em `share_minutes` a cada 15 s.
- `closer.go`: a cada minuto fecha horas completas (3 min de carência):
  TH/s = soma_diff × 2^32 ÷ 3600 ÷ 1e12; crédito = TH/s × taxa ÷ 24.
  Taxa vem de `rates` (a mais recente com effective_from <= hora).
  Índice único impede crédito duplicado. Horas creditadas nunca são
  recalculadas.
- `api.go`: somente leitura em 127.0.0.1:8080 (stats, workers, balance,
  ledger).
- Ledger é imutável: saldo = soma de `ledger_entries.amount_usd`. Nunca
  editar saldo; saques, bônus e ajustes são novos lançamentos.

Testado com pool e máquina simuladas: reescrita de usuário, contagem de
aceitos/rejeitados, bloqueio de nick desconhecido, crédito correto
(100 TH/s × 0,045 ÷ 24 = 0,1875) e idempotência do fechamento.

## Limitações conhecidas

- Shares em voo durante troca de dificuldade contam com a nova.
- Shares que chegam após o fechamento da hora não são creditados.
- Sem failover de pool.

## Convenções

- Conversar com o dono em português, de forma simples: ele não é
  desenvolvedor e não sabe usar git.
- Comentários e mensagens de log em português.
- Segredos (senha do banco, conta da pool) nunca no repositório; só no
  servidor.
