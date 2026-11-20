package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClientIPIgnoresSpoofedLeftmostForwardedFor(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "172.18.0.2:5555"
	req.Header.Set("X-Forwarded-For", "1.2.3.4, 198.51.100.7")
	if got := clientIP(req); got != "198.51.100.7" {
		t.Fatalf("clientIP = %q, want proxy-appended right-most entry", got)
	}
	req.Header.Set("X-Forwarded-For", "198.51.100.7")
	if got := clientIP(req); got != "198.51.100.7" {
		t.Fatalf("single entry: %q", got)
	}
}

func TestSpoofedForwardedForCannotResetGuestRateLimit(t *testing.T) {
	mux, _, _ := newFreeGateway(t, func(c *Config) { c.RequestsPerMinute = 1 })
	send := func(spoof string) int {
		req := chatRequest("172.18.0.2:1000")
		req.Header.Set("X-Forwarded-For", spoof+", 203.0.113.50")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code
	}
	if code := send("10.0.0.1"); code != http.StatusOK {
		t.Fatalf("first: %d", code)
	}
	if code := send("10.0.0.2"); code != http.StatusTooManyRequests {
		t.Fatalf("spoofed second request got %d, want 429", code)
	}
}

func TestReadOnlyEndpointsDoNotBurnRateLimit(t *testing.T) {
	mux, _, _ := newFreeGateway(t, func(c *Config) { c.RequestsPerMinute = 1 })
	for i := 0; i < 3; i++ {
		for _, path := range []string{"/v1/models", "/v1/me"} {
			req := httptest.NewRequest(http.MethodGet, path, nil)
			req.RemoteAddr = "203.0.113.60:1"
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				t.Fatalf("%s #%d: %d %s", path, i, rec.Code, rec.Body.String())
			}
		}
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.60:2"))
	if rec.Code != http.StatusOK {
		t.Fatalf("chat after reads should still be allowed, got %d", rec.Code)
	}
}

func TestMeStillWorksWhenGuestBudgetExhausted(t *testing.T) {
	mux, _, _ := newFreeGateway(t, func(c *Config) { c.AnonymousDailyTokens = 10 })
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.70:1")) // books 42 tokens > 10
	if rec.Code != http.StatusOK {
		t.Fatalf("first chat: %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.70:2"))
	if rec.Code != http.StatusPaymentRequired {
		t.Fatalf("second chat: %d want 402", rec.Code)
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/me", nil)
	req.RemoteAddr = "203.0.113.70:3"
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/v1/me: %d %s", rec.Code, rec.Body.String())
	}
	var me map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &me)
	if me["remaining"].(float64) != 0 {
		t.Fatalf("remaining = %v, want 0", me["remaining"])
	}
}

func gatewayWithUpstream(t *testing.T, handler http.HandlerFunc, timeoutSec int) http.Handler {
	t.Helper()
	up := httptest.NewServer(handler)
	t.Cleanup(up.Close)
	cfg := &Config{
		AdminToken:         testAdmin,
		DataFile:           filepath.Join(t.TempDir(), "data.json"),
		UpstreamBaseURL:    up.URL,
		UpstreamKeys:       []UpstreamKey{{Name: "secret-key-label", Key: "sk-live-xyz"}},
		UpstreamTimeoutSec: timeoutSec,
		Models:             []string{"deepseek-chat"},
		AllowAnonymous:     true,
		RequestsPerMinute:  1000,
	}
	cfg.applyDefaults()
	store, err := OpenStore(cfg.DataFile, 1000)
	if err != nil {
		t.Fatal(err)
	}
	return buildMux(mustGateway(t, cfg, store))
}

func TestUpstreamErrorsAreSanitized(t *testing.T) {
	mux := gatewayWithUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `internal trace for sk-live-xyz`)
	}, 30)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.80:1"))
	body := rec.Body.String()
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d", rec.Code)
	}
	if strings.Contains(body, "secret-key-label") || strings.Contains(body, "sk-live") || strings.Contains(body, "trace") {
		t.Fatalf("client-facing error leaks upstream details: %s", body)
	}
	if rec.Header().Get("X-DSG-Upstream-Key") != "" {
		t.Fatal("upstream key label must not be exposed in headers")
	}
}

func TestUpstreamClientErrorPassesThrough(t *testing.T) {
	mux := gatewayWithUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"error":{"message":"Model Not Exist","type":"invalid_request_error"}}`)
	}, 30)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.81:1"))
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "Model Not Exist") {
		t.Fatalf("got %d %s", rec.Code, rec.Body.String())
	}
}

func TestLongStreamIsNotCutByUpstreamTimeout(t *testing.T) {
	mux := gatewayWithUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fl := w.(http.Flusher)
		for i := 0; i < 6; i++ {
			_, _ = io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n")
			fl.Flush()
			time.Sleep(300 * time.Millisecond)
		}
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	}, 1) // 1s header timeout, stream lasts ~1.8s
	srv := httptest.NewServer(mux)
	defer srv.Close()
	resp, err := http.Post(srv.URL+"/v1/chat/completions", "application/json",
		strings.NewReader(`{"model":"deepseek-chat","stream":true,"messages":[{"role":"user","content":"hi"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(raw), "[DONE]") || strings.Count(string(raw), `"content":"x"`) != 6 {
		t.Fatalf("stream was truncated: %q", raw)
	}
}

func TestGuestLedgerPrunesPreviousDays(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "data.json"), 1000)
	if err != nil {
		t.Fatal(err)
	}
	store.guests["stale"] = &guestEntry{Day: "2000-01-01", Used: 99}
	store.ConsumeGuest("fresh", 5, 100, 1000)
	if _, ok := store.guests["stale"]; ok {
		t.Fatal("stale guest ledger should be pruned")
	}
	if store.guests["fresh"].Used != 5 {
		t.Fatal("today's ledger must survive")
	}
}

func TestRateLimitCooldownIsCapped(t *testing.T) {
	pool := NewUpstreamPool(&Config{UpstreamKeys: []UpstreamKey{{Name: "k", Key: "v"}}})
	for i := 0; i < 100; i++ {
		pool.Report("k", http.StatusTooManyRequests)
	}
	if wait := time.Until(pool.keys[0].CoolUntil); wait > maxRateLimitCooldown+time.Second {
		t.Fatalf("cooldown %v exceeds cap", wait)
	}
}
