package main

import (
	"context"
	"log"
	"sync"
	"time"
)

type aggKey struct {
	nick, worker string
	minute       time.Time
}

type agg struct {
	sumDiff  float64
	accepted int64
	rejected int64
	last     time.Time
}

// Recorder agrega shares em memória por minuto e grava no banco a cada 15s.
type Recorder struct {
	store *Store
	mu    sync.Mutex
	buf   map[aggKey]*agg
}

func NewRecorder(st *Store) *Recorder {
	return &Recorder{store: st, buf: map[aggKey]*agg{}}
}

func (r *Recorder) Add(nick, worker string, diff float64, accepted bool) {
	now := time.Now().UTC()
	k := aggKey{nick, worker, now.Truncate(time.Minute)}
	r.mu.Lock()
	a := r.buf[k]
	if a == nil {
		a = &agg{}
		r.buf[k] = a
	}
	if accepted {
		a.sumDiff += diff
		a.accepted++
	} else {
		a.rejected++
	}
	a.last = now
	r.mu.Unlock()
}

func (r *Recorder) Run(ctx context.Context) {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			r.Flush(ctx)
		}
	}
}

func (r *Recorder) Flush(ctx context.Context) {
	r.mu.Lock()
	batch := r.buf
	r.buf = map[aggKey]*agg{}
	r.mu.Unlock()
	if len(batch) == 0 {
		return
	}
	if err := r.write(ctx, batch); err != nil {
		log.Printf("falha gravando shares (vou tentar de novo): %v", err)
		r.mu.Lock()
		for k, a := range batch { // devolve para o buffer
			if b := r.buf[k]; b != nil {
				b.sumDiff += a.sumDiff
				b.accepted += a.accepted
				b.rejected += a.rejected
				if a.last.After(b.last) {
					b.last = a.last
				}
			} else {
				r.buf[k] = a
			}
		}
		r.mu.Unlock()
	}
}

func (r *Recorder) write(ctx context.Context, batch map[aggKey]*agg) error {
	tx, err := r.store.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for k, a := range batch {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO share_minutes (nick, worker, minute, sum_diff, accepted, rejected)
			VALUES ($1,$2,$3,$4,$5,$6)
			ON CONFLICT (nick, worker, minute) DO UPDATE SET
				sum_diff = share_minutes.sum_diff + EXCLUDED.sum_diff,
				accepted = share_minutes.accepted + EXCLUDED.accepted,
				rejected = share_minutes.rejected + EXCLUDED.rejected`,
			k.nick, k.worker, k.minute, a.sumDiff, a.accepted, a.rejected); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO workers (nick, worker, last_share_at) VALUES ($1,$2,$3)
			ON CONFLICT (nick, worker) DO UPDATE SET
				last_share_at = GREATEST(workers.last_share_at, EXCLUDED.last_share_at)`,
			k.nick, k.worker, a.last); err != nil {
			return err
		}
	}
	return tx.Commit()
}
