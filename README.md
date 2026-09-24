# hashproxy — proxy stratum com medição e crédito em USD

Recebe as máquinas dos clientes, repassa para a sua conta na pool e mede
quanto cada cliente entregou. A cada hora fechada, credita no ledger:

    TH/s médio da hora × taxa (USD por TH/s por dia) ÷ 24

## Subir

1. `cp .env.example .env` e preencha `POOL_ADDR`, `POOL_USER` e a senha do
   banco. O `.env` fica só no servidor (está no `.gitignore`).

Guia passo a passo para o teste com hashrate alugada: `COMO_TESTAR.md`.
2. `docker compose up -d --build`
3. Cadastre a taxa e um cliente:

```sql
-- docker compose exec db psql -U hp hp
INSERT INTO rates VALUES (now(), 0.045);
INSERT INTO users (nick) VALUES ('meunick');
```

4. Na máquina: pool `stratum+tcp://IP_DO_SERVIDOR:3333`,
   usuário `meunick.maquina1`, senha `x`.

Na pool, a máquina aparece como `SUA_CONTA.meunick_maquina1`, então dá
para conferir a medição do proxy contra o painel da pool.

## Mudar a taxa

Insira uma nova linha em `rates`. Vale a partir de `effective_from`;
horas já creditadas não mudam.

## API (só em 127.0.0.1:8080)

- `GET /api/stats` — TH/s total (15 min) e máquinas online
- `GET /api/users/{nick}/workers` — máquinas, TH/s 15 min, online
- `GET /api/users/{nick}/balance` — saldo em USD
- `GET /api/users/{nick}/ledger?limit=100` — extrato

## Como funciona

- Uma conexão com a pool por máquina; tudo passa direto, exceto
  `mining.authorize` e `mining.submit`, que têm o usuário reescrito.
- Nick que não está em `users` (ou `active = false`) é recusado.
- Shares aceitos somam a dificuldade vigente; agregados por minuto e
  gravados a cada 15 s em `share_minutes`.
- `client.reconnect` da pool é bloqueado (senão a máquina sairia do proxy).
- A hora fecha 3 min após terminar; índice único impede crédito duplicado.

## Limitações conhecidas (MVP)

- Se a pool muda a dificuldade, os shares em voo ainda contam com a
  dificuldade nova. Diferença pequena na prática; dá para refinar.
- Shares que chegarem depois de a hora fechar não são creditados.
- Sem failover de pool, sem saques e sem painel ainda.
