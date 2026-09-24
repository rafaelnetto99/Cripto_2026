package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"time"
)

// API somente leitura para o painel. Por padrão escuta só em 127.0.0.1.
func RunAPI(ctx context.Context, addr string, st *Store) {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/users/{nick}/workers", func(w http.ResponseWriter, r *http.Request) {
		rows, err := st.db.QueryContext(r.Context(), `
			SELECT w.worker, w.last_share_at,
			       COALESCE(SUM(s.sum_diff),0) * 4294967296 / 900 / 1e12 AS ths_15m
			FROM workers w
			LEFT JOIN share_minutes s ON s.nick = w.nick AND s.worker = w.worker
			     AND s.minute >= now() - interval '15 minutes'
			WHERE w.nick = $1
			GROUP BY w.worker, w.last_share_at
			ORDER BY w.worker`, r.PathValue("nick"))
		if err != nil {
			httpErr(w, err)
			return
		}
		defer rows.Close()
		type worker struct {
			Worker      string    `json:"worker"`
			LastShareAt time.Time `json:"last_share_at"`
			THs15m      float64   `json:"ths_15m"`
			Online      bool      `json:"online"`
		}
		out := []worker{}
		for rows.Next() {
			var x worker
			if err := rows.Scan(&x.Worker, &x.LastShareAt, &x.THs15m); err != nil {
				httpErr(w, err)
				return
			}
			x.Online = time.Since(x.LastShareAt) < 10*time.Minute
			out = append(out, x)
		}
		writeJSON(w, out)
	})

	mux.HandleFunc("GET /api/users/{nick}/balance", func(w http.ResponseWriter, r *http.Request) {
		var bal string
		err := st.db.QueryRowContext(r.Context(),
			`SELECT COALESCE(SUM(amount_usd),0)::text FROM ledger_entries WHERE nick = $1`,
			r.PathValue("nick")).Scan(&bal)
		if err != nil {
			httpErr(w, err)
			return
		}
		writeJSON(w, map[string]string{"nick": r.PathValue("nick"), "balance_usd": bal})
	})

	mux.HandleFunc("GET /api/users/{nick}/ledger", func(w http.ResponseWriter, r *http.Request) {
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		if limit <= 0 || limit > 500 {
			limit = 100
		}
		rows, err := st.db.QueryContext(r.Context(), `
			SELECT kind, hour, COALESCE(ths_avg::text,''), COALESCE(rate_usd_th_day::text,''),
			       amount_usd::text, created_at
			FROM ledger_entries WHERE nick = $1
			ORDER BY created_at DESC, id DESC LIMIT $2`, r.PathValue("nick"), limit)
		if err != nil {
			httpErr(w, err)
			return
		}
		defer rows.Close()
		type entry struct {
			Kind      string     `json:"kind"`
			Hour      *time.Time `json:"hour,omitempty"`
			THsAvg    string     `json:"ths_avg,omitempty"`
			Rate      string     `json:"rate_usd_th_day,omitempty"`
			AmountUSD string     `json:"amount_usd"`
			CreatedAt time.Time  `json:"created_at"`
		}
		out := []entry{}
		for rows.Next() {
			var e entry
			if err := rows.Scan(&e.Kind, &e.Hour, &e.THsAvg, &e.Rate, &e.AmountUSD, &e.CreatedAt); err != nil {
				httpErr(w, err)
				return
			}
			out = append(out, e)
		}
		writeJSON(w, out)
	})

	mux.HandleFunc("GET /api/stats", func(w http.ResponseWriter, r *http.Request) {
		var ths float64
		var online int
		st.db.QueryRowContext(r.Context(), `
			SELECT COALESCE(SUM(sum_diff),0) * 4294967296 / 900 / 1e12 FROM share_minutes
			WHERE minute >= now() - interval '15 minutes'`).Scan(&ths)
		st.db.QueryRowContext(r.Context(), `
			SELECT COUNT(*) FROM workers WHERE last_share_at > now() - interval '10 minutes'`).Scan(&online)
		writeJSON(w, map[string]any{"ths_total_15m": ths, "workers_online": online})
	})

	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { <-ctx.Done(); srv.Shutdown(context.Background()) }()
	log.Printf("API em http://%s", addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Printf("API: %v", err)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, err error) {
	log.Printf("api: %v", err)
	http.Error(w, "erro interno", http.StatusInternalServerError)
}
