package main

import (
	"context"
	"database/sql"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	_ "github.com/lib/pq"
)

type Config struct {
	ListenAddr  string // onde as máquinas conectam
	APIAddr     string // API de leitura (painel)
	PoolAddr    string // pool upstream host:porta
	PoolUser    string // sua conta na pool
	PoolPass    string
	DatabaseURL string
}

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func main() {
	cfg := Config{
		ListenAddr:  env("LISTEN_ADDR", ":3333"),
		APIAddr:     env("API_ADDR", "127.0.0.1:8080"),
		PoolAddr:    env("POOL_ADDR", ""),
		PoolUser:    env("POOL_USER", ""),
		PoolPass:    env("POOL_PASS", "x"),
		DatabaseURL: env("DATABASE_URL", ""),
	}
	if cfg.PoolAddr == "" || cfg.PoolUser == "" || cfg.DatabaseURL == "" {
		log.Fatal("defina POOL_ADDR, POOL_USER e DATABASE_URL")
	}

	db, err := sql.Open("postgres", cfg.DatabaseURL)
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(20)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		log.Fatalf("banco indisponível: %v", err)
	}

	store := &Store{db: db}
	rec := NewRecorder(store)
	go rec.Run(ctx)
	go RunHourlyCloser(ctx, store)
	go RunAPI(ctx, cfg.APIAddr, store)

	ln, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("proxy stratum em %s -> pool %s", cfg.ListenAddr, cfg.PoolAddr)

	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			log.Printf("accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go handleMiner(cfg, c, store, rec)
	}
	log.Print("encerrando, gravando shares pendentes...")
	rec.Flush(context.Background())
}
