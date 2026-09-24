package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	maxLine     = 16 * 1024
	idleTimeout = 10 * time.Minute
	writeTO     = 10 * time.Second
)

var (
	sessionSeq uint64
	nickRe     = regexp.MustCompile(`^[a-z0-9_]{3,32}$`)
	workerBad  = regexp.MustCompile(`[^A-Za-z0-9_\-]`)
)

// Mensagem stratum v1 (JSON-RPC por linha).
type msg struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  json.RawMessage `json:"error,omitempty"`
}

type pending struct {
	kind string // "auth" ou "submit"
	diff float64
}

type lineWriter struct {
	mu sync.Mutex
	c  net.Conn
}

func (w *lineWriter) write(b []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.c.SetWriteDeadline(time.Now().Add(writeTO))
	if len(b) == 0 || b[len(b)-1] != '\n' {
		b = append(b, '\n')
	}
	_, err := w.c.Write(b)
	return err
}

type session struct {
	id    uint64
	cfg   Config
	store *Store
	rec   *Recorder
	miner *lineWriter
	pool  *lineWriter

	mu         sync.Mutex
	nick       string
	worker     string
	poolWorker string
	authorized bool
	difficulty float64
	pending    map[string]pending
}

func handleMiner(cfg Config, mc net.Conn, store *Store, rec *Recorder) {
	defer mc.Close()
	pc, err := net.DialTimeout("tcp", cfg.PoolAddr, 10*time.Second)
	if err != nil {
		log.Printf("pool indisponível (%s): %v", cfg.PoolAddr, err)
		return
	}
	defer pc.Close()

	s := &session{
		id:         atomic.AddUint64(&sessionSeq, 1),
		cfg:        cfg,
		store:      store,
		rec:        rec,
		miner:      &lineWriter{c: mc},
		pool:       &lineWriter{c: pc},
		difficulty: 1,
		pending:    map[string]pending{},
	}
	log.Printf("[%d] conexão de %s", s.id, mc.RemoteAddr())

	done := make(chan struct{}, 2)
	go func() { s.loop(pc, s.fromPool); done <- struct{}{} }()
	go func() { s.loop(mc, s.fromMiner); done <- struct{}{} }()
	<-done // qualquer lado caiu: fecha tudo (defers)

	s.mu.Lock()
	log.Printf("[%d] desconectado (%s.%s)", s.id, s.nick, s.worker)
	s.mu.Unlock()
}

// loop lê linhas de uma conexão e entrega para o handler.
func (s *session) loop(c net.Conn, handle func([]byte) error) {
	r := bufio.NewReaderSize(c, maxLine)
	for {
		c.SetReadDeadline(time.Now().Add(idleTimeout))
		line, err := r.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			log.Printf("[%d] linha grande demais, fechando", s.id)
			return
		}
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				log.Printf("[%d] leitura: %v", s.id, err)
			}
			return
		}
		line = append([]byte(nil), line...)
		if len(strings.TrimSpace(string(line))) == 0 {
			continue
		}
		if err := handle(line); err != nil {
			log.Printf("[%d] %v", s.id, err)
			return
		}
	}
}

func (s *session) replyMiner(id json.RawMessage, result any, errObj any) error {
	b, _ := json.Marshal(map[string]any{"id": id, "result": result, "error": errObj})
	return s.miner.write(b)
}

// ---- máquina -> pool ----

func (s *session) fromMiner(line []byte) error {
	var m msg
	if err := json.Unmarshal(line, &m); err != nil {
		return fmt.Errorf("json inválido da máquina: %w", err)
	}
	switch m.Method {
	case "mining.authorize":
		return s.handleAuthorize(m)
	case "mining.submit":
		return s.handleSubmit(m)
	default:
		// subscribe, configure, extranonce.subscribe etc. passam direto
		return s.pool.write(line)
	}
}

func parseUser(user string) (nick, worker string) {
	user = strings.TrimSpace(user)
	nick, worker, _ = strings.Cut(user, ".")
	nick = strings.ToLower(nick)
	worker = workerBad.ReplaceAllString(worker, "")
	if worker == "" {
		worker = "default"
	}
	if len(worker) > 32 {
		worker = worker[:32]
	}
	return
}

func (s *session) handleAuthorize(m msg) error {
	var params []json.RawMessage
	var user string
	if json.Unmarshal(m.Params, &params) != nil || len(params) < 1 || json.Unmarshal(params[0], &user) != nil {
		return s.replyMiner(m.ID, false, []any{20, "params inválidos", nil})
	}
	nick, worker := parseUser(user)
	if !nickRe.MatchString(nick) {
		return s.replyMiner(m.ID, false, []any{24, "usuário inválido", nil})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	ok, err := s.store.NickActive(ctx, nick)
	cancel()
	if err != nil {
		log.Printf("[%d] erro checando nick: %v", s.id, err)
		return s.replyMiner(m.ID, false, []any{20, "erro interno", nil})
	}
	if !ok {
		log.Printf("[%d] nick desconhecido: %q", s.id, nick)
		return s.replyMiner(m.ID, false, []any{24, "usuário não cadastrado", nil})
	}

	// Na pool, cada máquina aparece como POOL_USER.nick_worker
	pw := s.cfg.PoolUser + "." + nick + "_" + worker
	s.mu.Lock()
	s.nick, s.worker, s.poolWorker = nick, worker, pw
	s.pending[string(m.ID)] = pending{kind: "auth"}
	s.mu.Unlock()

	b, _ := json.Marshal(map[string]any{
		"id": m.ID, "method": "mining.authorize", "params": []string{pw, s.cfg.PoolPass},
	})
	return s.pool.write(b)
}

func (s *session) handleSubmit(m msg) error {
	var params []json.RawMessage
	if json.Unmarshal(m.Params, &params) != nil || len(params) < 5 {
		return s.replyMiner(m.ID, false, []any{20, "params inválidos", nil})
	}
	s.mu.Lock()
	if !s.authorized {
		s.mu.Unlock()
		return s.replyMiner(m.ID, false, []any{24, "não autorizado", nil})
	}
	pw := s.poolWorker
	s.pending[string(m.ID)] = pending{kind: "submit", diff: s.difficulty}
	s.mu.Unlock()

	params[0], _ = json.Marshal(pw)
	b, _ := json.Marshal(map[string]any{"id": m.ID, "method": "mining.submit", "params": params})
	return s.pool.write(b)
}

// ---- pool -> máquina ----

func (s *session) fromPool(line []byte) error {
	var m msg
	if err := json.Unmarshal(line, &m); err != nil {
		return fmt.Errorf("json inválido da pool: %w", err)
	}

	if m.Method != "" { // notificação da pool
		switch m.Method {
		case "mining.set_difficulty":
			var p []float64
			if json.Unmarshal(m.Params, &p) == nil && len(p) > 0 && p[0] > 0 {
				s.mu.Lock()
				s.difficulty = p[0]
				s.mu.Unlock()
			}
		case "client.reconnect":
			// Nunca repassar: a máquina iria direto para a pool e sairia da medição.
			return errors.New("pool pediu reconnect; derrubando sessão para a máquina reconectar em nós")
		}
		return s.miner.write(line)
	}

	// resposta a um pedido da máquina
	s.mu.Lock()
	p, ok := s.pending[string(m.ID)]
	if ok {
		delete(s.pending, string(m.ID))
	}
	nick, worker := s.nick, s.worker
	accepted := string(m.Result) == "true"
	if ok && p.kind == "auth" {
		s.authorized = accepted
	}
	s.mu.Unlock()

	if ok {
		switch p.kind {
		case "auth":
			log.Printf("[%d] autorizado=%v %s.%s", s.id, accepted, nick, worker)
		case "submit":
			s.rec.Add(nick, worker, p.diff, accepted)
		}
	}
	return s.miner.write(line)
}
