package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

const testAdmin = "test-admin-token-0123456789"

// fakeUpstream emulates an OpenAI-compatible SSE provider and records what it saw.
type fakeUpstream struct {
	hits        int
	lastAuth    string
	lastBody    map[string]any
	status      int
	usageTokens int
	failFirstN  int
	srv         *httptest.Server
}

func mustGateway(t *testing.T, cfg *Config, store *Store) *Gateway {
	t.Helper()
	gw, err := NewGateway(cfg, store, NewUpstreamPool(cfg))
	if err != nil {
		t.Fatalf("new gateway: %v", err)
	}
	return gw
}

func newFakeUpstream(t *testing.T, usageTokens, failFirstN int) *fakeUpstream {
	t.Helper()
	f := &fakeUpstream{status: http.StatusOK, usageTokens: usageTokens, failFirstN: failFirstN}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.hits++
		if f.hits <= f.failFirstN {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, `{"error":"rate limited"}`)
			return
		}
		f.lastAuth = r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &f.lastBody)

		stream, _ := f.lastBody["stream"].(bool)
		if !stream {
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprintf(w, `{"id":"x","choices":[{"message":{"role":"assistant","content":"hello"}}],"usage":{"prompt_tokens":10,"completion_tokens":%d,"total_tokens":%d}}`,
				f.usageTokens, f.usageTokens+10)
			return
		}

		w.Header().Set("Content-Type", "text/event-stream")
		fl := w.(http.Flusher)
		_, _ = io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n")
		fl.Flush()
		_, _ = io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n")
		fl.Flush()
		_, _ = fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":%d,\"total_tokens\":%d}}\n\n",
			f.usageTokens, f.usageTokens+10)
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
		fl.Flush()
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func newTestGateway(t *testing.T, quota int64) (*Gateway, http.Handler, *Store) {
	t.Helper()
	up := newFakeUpstream(t, 32, 0)
	cfg := &Config{
		Listen:              "127.0.0.1:0",
		AdminToken:          testAdmin,
		DataFile:            filepath.Join(t.TempDir(), "data.json"),
		UpstreamBaseURL:     up.srv.URL,
		UpstreamKeys:        []UpstreamKey{{Name: "k1", Key: "upstream-secret"}},
		DefaultMonthlyQuota: quota,
		MaxTokensPerRequest: 4096,
		UpstreamTimeoutSec:  30,
		Models:              []string{"deepseek-chat", "deepseek-reasoner"},
	}
	cfg.applyDefaults()
	store, err := OpenStore(cfg.DataFile, cfg.DefaultMonthlyQuota)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	gw := mustGateway(t, cfg, store)
	return gw, buildMux(gw), store
}

func TestUnauthorizedIsRejected(t *testing.T) {
	_, mux, _ := newTestGateway(t, 1000)

	for _, path := range []string{"/v1/models", "/v1/chat/completions"} {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{}`))
		if path == "/v1/models" {
			req = httptest.NewRequest(http.MethodGet, path, nil)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s: got %d want 401", path, rec.Code)
		}
	}
}

func TestAdminIssuesWorkingToken(t *testing.T) {
	_, mux, _ := newTestGateway(t, 5000)

	body := `{"note":"alice@example.com","plan":"pro.monthly"}`
	req := httptest.NewRequest(http.MethodPost, "/admin/users", strings.NewReader(body))
	req.Header.Set("X-Admin-Token", testAdmin)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create user: %d %s", rec.Code, rec.Body.String())
	}
	var created struct {
		Token string `json:"token"`
		User  User   `json:"user"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(created.Token, "dsg_") {
		t.Fatalf("unexpected token %q", created.Token)
	}
	if created.User.MonthlyQuota != -1 {
		t.Fatalf("pro plan should be unlimited, got %d", created.User.MonthlyQuota)
	}

	req = httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+created.Token)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("models with issued token: %d %s", rec.Code, rec.Body.String())
	}
}

func TestStreamPassthroughMetersUsage(t *testing.T) {
	up := newFakeUpstream(t, 32, 0)
	cfg := &Config{
		AdminToken:          testAdmin,
		DataFile:            filepath.Join(t.TempDir(), "data.json"),
		UpstreamBaseURL:     up.srv.URL,
		UpstreamKeys:        []UpstreamKey{{Name: "k1", Key: "upstream-secret"}},
		DefaultMonthlyQuota: 100000,
		MaxTokensPerRequest: 4096,
		UpstreamTimeoutSec:  30,
		Models:              []string{"deepseek-chat"},
	}
	cfg.applyDefaults()
	store, _ := OpenStore(cfg.DataFile, cfg.DefaultMonthlyQuota)
	user, token, err := store.CreateUser("bob", "starter", 1000)
	if err != nil {
		t.Fatal(err)
	}
	gw := mustGateway(t, cfg, store)
	mux := buildMux(gw)

	payload := `{"model":"deepseek-chat","stream":true,"max_tokens":999999,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("stream: %d %s", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); !strings.Contains(got, "hel") || !strings.Contains(got, "lo") {
		t.Fatalf("stream body not forwarded: %q", got)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/event-stream") {
		t.Fatalf("content-type %q", ct)
	}
	// Client asked for 999999 max_tokens; gateway must clamp to 4096.
	if mt, _ := up.lastBody["max_tokens"].(float64); int(mt) != 4096 {
		t.Fatalf("max_tokens not clamped: %v", up.lastBody["max_tokens"])
	}
	if so, _ := up.lastBody["stream_options"].(map[string]any); so["include_usage"] != true {
		t.Fatalf("stream_options.include_usage not injected: %v", up.lastBody["stream_options"])
	}
	if up.lastAuth != "Bearer upstream-secret" {
		t.Fatalf("upstream auth %q", up.lastAuth)
	}

	snap, _ := store.Snapshot(user.ID)
	if snap.Used != 42 {
		t.Fatalf("usage accounting: got %d want 42", snap.Used)
	}
}

func TestQuotaExhaustedReturns402(t *testing.T) {
	_, mux, store := newTestGateway(t, 10)
	user, token, err := store.CreateUser("carol", "starter", 10)
	if err != nil {
		t.Fatal(err)
	}
	store.Consume(user.ID, 10)

	payload := `{"model":"deepseek-chat","stream":false,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusPaymentRequired {
		t.Fatalf("got %d want 402 (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "quota_exceeded") {
		t.Fatalf("body %s", rec.Body.String())
	}
}

func TestRetriesOnUpstream429(t *testing.T) {
	up := newFakeUpstream(t, 5, 1) // first call 429, then OK
	cfg := &Config{
		AdminToken:          testAdmin,
		DataFile:            filepath.Join(t.TempDir(), "data.json"),
		UpstreamBaseURL:     up.srv.URL,
		UpstreamKeys:        []UpstreamKey{{Name: "k1", Key: "a"}, {Name: "k2", Key: "b"}},
		DefaultMonthlyQuota: 1000,
		MaxTokensPerRequest: 100,
		UpstreamTimeoutSec:  30,
		Models:              []string{"deepseek-chat"},
	}
	cfg.applyDefaults()
	store, _ := OpenStore(cfg.DataFile, cfg.DefaultMonthlyQuota)
	_, token, _ := store.CreateUser("dave", "starter", 1000)
	gw := mustGateway(t, cfg, store)
	mux := buildMux(gw)

	payload := `{"model":"deepseek-chat","stream":false,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected failover to succeed, got %d %s", rec.Code, rec.Body.String())
	}
	if up.hits != 2 {
		t.Fatalf("expected 2 upstream attempts, got %d", up.hits)
	}
}

func TestUsageSnifferHandlesSplitChunks(t *testing.T) {
	var s usageSniffer
	s.Feed([]byte(`data: {"choices":[{"delta":{"content":"a"}}]}` + "\n\n"))
	s.Feed([]byte(`data: {"usage":{"prompt_tokens":7,"completion_tokens":3,"tot`))
	if s.Total() != 0 {
		t.Fatalf("partial line must not count")
	}
	s.Feed([]byte(`al_tokens":10}}` + "\n\ndata: [DONE]\n\n"))
	if s.Total() != 10 {
		t.Fatalf("got %d want 10", s.Total())
	}
}
