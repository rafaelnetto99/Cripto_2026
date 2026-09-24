package main

import (
	"context"
	"database/sql"
	"sync"
	"time"
)

type Store struct {
	db *sql.DB

	mu        sync.Mutex
	nickCache map[string]nickCacheEntry
}

type nickCacheEntry struct {
	ok  bool
	exp time.Time
}

// NickActive diz se o nick existe e está ativo (com cache de 1 min).
func (s *Store) NickActive(ctx context.Context, nick string) (bool, error) {
	s.mu.Lock()
	if s.nickCache == nil {
		s.nickCache = map[string]nickCacheEntry{}
	}
	if e, ok := s.nickCache[nick]; ok && time.Now().Before(e.exp) {
		s.mu.Unlock()
		return e.ok, nil
	}
	s.mu.Unlock()

	var active bool
	err := s.db.QueryRowContext(ctx, `SELECT active FROM users WHERE nick = $1`, nick).Scan(&active)
	if err == sql.ErrNoRows {
		active = false
	} else if err != nil {
		return false, err
	}
	s.mu.Lock()
	s.nickCache[nick] = nickCacheEntry{ok: active, exp: time.Now().Add(time.Minute)}
	s.mu.Unlock()
	return active, nil
}
