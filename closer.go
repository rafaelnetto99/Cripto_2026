package main

import (
	"context"
	"log"
	"time"
)

// Fecha as horas completas: converte shares em TH/s médio e credita USD no ledger.
// Uma hora só fecha 3 min depois de terminar (tempo para o flush dos shares).
// O índice único garante que cada hora é creditada uma única vez.
const closeHoursSQL = `
INSERT INTO ledger_entries (nick, kind, hour, ths_avg, rate_usd_th_day, amount_usd)
SELECT t.nick, 'hashrate', t.h, t.ths, r.usd_per_th_day,
       ROUND(t.ths * r.usd_per_th_day / 24, 8)
FROM (
    SELECT nick, date_trunc('hour', minute) AS h,
           (SUM(sum_diff) * 4294967296 / 3600 / 1e12)::numeric AS ths
    FROM share_minutes
    WHERE minute >= now() - interval '48 hours'
      AND date_trunc('hour', minute) + interval '1 hour' <= now() - interval '3 minutes'
    GROUP BY nick, date_trunc('hour', minute)
) t
JOIN LATERAL (
    SELECT usd_per_th_day FROM rates
    WHERE effective_from <= t.h
    ORDER BY effective_from DESC LIMIT 1
) r ON TRUE
WHERE t.ths > 0
ON CONFLICT (nick, kind, hour) WHERE hour IS NOT NULL DO NOTHING`

func CloseHours(ctx context.Context, st *Store) (int64, error) {
	res, err := st.db.ExecContext(ctx, closeHoursSQL)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func RunHourlyCloser(ctx context.Context, st *Store) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		n, err := CloseHours(ctx, st)
		if err != nil {
			log.Printf("fechamento de hora falhou: %v", err)
		} else if n > 0 {
			log.Printf("fechamento: %d créditos por hora lançados", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
