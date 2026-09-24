# Como testar o proxy com hashrate alugada

Ideia do teste: comprar um pouco de hashrate (hashsell.com, NiceHash,
MiningRigRentals etc.), apontar para o nosso proxy e conferir se três
números batem:

1. o TH/s que o **vendedor** diz que entregou
2. o TH/s que o **proxy** mediu
3. o TH/s que a **pool** registrou (e quanto ela pagou em BTC)

Se os três ficarem próximos (poucos % de diferença), a medição está certa.

## O que você precisa antes

- **Conta numa pool** SHA-256 com pagamento FPPS em BTC (ex.: ViaBTC,
  F2Pool, Antpool). Anote o endereço stratum (ex.: `btc.pool.com:3333`) e
  o nome da conta.
- **Um servidor na nuvem (VPS)** com Ubuntu e IP público. O mais barato
  serve (1 CPU, 1 GB de RAM). A hashrate alugada chega pela internet,
  então um computador em casa não funciona.
- **Porta 3333 liberada** no firewall do servidor (no painel do provedor
  da VPS, procure por "firewall" ou "security group").

## Passo 1 — preparar o servidor

Entre no servidor (o provedor mostra como, geralmente pelo navegador ou
`ssh root@IP`) e cole, um por vez:

```sh
curl -fsSL https://get.docker.com | sh
git clone https://github.com/rafaelnetto99/Cripto_2026.git
cd Cripto_2026
cp .env.example .env
nano .env
```

No `nano`, preencha `DB_PASSWORD` (invente uma senha só com letras e
números), `POOL_ADDR` e `POOL_USER`. Salve com Ctrl+O, Enter, e saia com
Ctrl+X.

## Passo 2 — ligar o proxy

```sh
docker compose up -d --build
docker compose logs proxy
```

O log deve mostrar `proxy stratum em :3333 -> pool ...`.

## Passo 3 — cadastrar taxa e usuário de teste

```sh
docker compose exec db psql -U hp hp -c "INSERT INTO rates VALUES (now(), 0.045);"
docker compose exec db psql -U hp hp -c "INSERT INTO users (nick) VALUES ('teste');"
```

(0.045 é só um exemplo de USD por TH/s por dia.)

## Passo 4 — comprar a hashrate

No site de aluguel, ao cadastrar a pool de destino, use:

- **Pool / URL:** `stratum+tcp://IP_DO_SERVIDOR:3333`
- **Usuário / worker:** `teste.aluguel1`
- **Senha:** `x`

Sugestão para o primeiro teste: pouca hashrate, por **6 a 12 horas**.
Alugar costuma custar mais do que a pool paga, então o teste terá um
pequeno custo; o objetivo aqui é medir, não lucrar.

## Passo 5 — acompanhar

No servidor:

```sh
docker compose logs -f proxy                          # conexões e autorizações (Ctrl+C sai)
curl -s localhost:8080/api/stats                      # TH/s total (últimos 15 min)
curl -s localhost:8080/api/users/teste/workers        # por máquina
curl -s localhost:8080/api/users/teste/ledger         # créditos por hora (TH/s médio de cada hora)
curl -s localhost:8080/api/users/teste/balance        # saldo em USD
```

Na pool, a hashrate aparece como `SUA_CONTA.teste_aluguel1`.

## Passo 6 — comparar

Ao final, anote para cada hora: TH/s do vendedor, TH/s do extrato
(`ledger`) e TH/s do painel da pool. Some também o que a pool pagou em
BTC no período. Mande esses números para o Claude fazer as contas da
margem.

## Se algo der errado

- **Vendedor diz que a pool está offline:** confira a porta 3333 no
  firewall e se `docker compose ps` mostra o proxy rodando.
- **Log mostra `nick desconhecido`:** o usuário na compra não bate com o
  cadastrado no passo 3 (tem que ser `teste.algumacoisa`, minúsculo).
- **Log mostra `pool indisponível`:** `POOL_ADDR` errado no `.env`.
  Corrija e rode `docker compose up -d` de novo.
