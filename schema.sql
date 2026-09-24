-- Contas de clientes. O nick é o que o cliente usa como usuário na máquina.
CREATE TABLE IF NOT EXISTS users (
    nick        TEXT PRIMARY KEY CHECK (nick ~ '^[a-z0-9_]{3,32}$'),
    active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Máquinas vistas por cliente.
CREATE TABLE IF NOT EXISTS workers (
    nick           TEXT NOT NULL REFERENCES users(nick),
    worker         TEXT NOT NULL,
    first_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_share_at  TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (nick, worker)
);

-- Shares agregados por minuto (soma das dificuldades aceitas).
CREATE TABLE IF NOT EXISTS share_minutes (
    nick      TEXT NOT NULL,
    worker    TEXT NOT NULL,
    minute    TIMESTAMPTZ NOT NULL,
    sum_diff  DOUBLE PRECISION NOT NULL DEFAULT 0,
    accepted  BIGINT NOT NULL DEFAULT 0,
    rejected  BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (nick, worker, minute)
);
CREATE INDEX IF NOT EXISTS share_minutes_minute_idx ON share_minutes (minute);

-- Taxa paga por TH/s por dia. A mais recente com effective_from <= hora vale.
CREATE TABLE IF NOT EXISTS rates (
    effective_from  TIMESTAMPTZ PRIMARY KEY,
    usd_per_th_day  NUMERIC(18,8) NOT NULL CHECK (usd_per_th_day >= 0)
);

-- Livro-razão imutável. Saldo = soma de amount_usd.
-- kind: 'hashrate' (crédito por hora), 'withdrawal' (negativo), 'bonus', 'referral', 'adjustment'
CREATE TABLE IF NOT EXISTS ledger_entries (
    id               BIGSERIAL PRIMARY KEY,
    nick             TEXT NOT NULL REFERENCES users(nick),
    kind             TEXT NOT NULL,
    hour             TIMESTAMPTZ,
    ths_avg          NUMERIC(24,6),
    rate_usd_th_day  NUMERIC(18,8),
    amount_usd       NUMERIC(24,8) NOT NULL,
    note             TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Garante que cada hora só é creditada uma vez por cliente.
CREATE UNIQUE INDEX IF NOT EXISTS ledger_hour_uniq ON ledger_entries (nick, kind, hour) WHERE hour IS NOT NULL;

CREATE OR REPLACE VIEW balances AS
    SELECT nick, COALESCE(SUM(amount_usd), 0) AS balance_usd
    FROM ledger_entries GROUP BY nick;
