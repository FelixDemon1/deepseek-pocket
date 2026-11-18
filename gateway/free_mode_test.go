package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func newFreeGateway(t *testing.T, mutate func(*Config)) (http.Handler, *Store, *fakeUpstream) {
	t.Helper()
	up := newFakeUpstream(t, 32, 0)
	cfg := &Config{
		Listen:               "127.0.0.1:8787",
		AdminToken:           testAdmin,
		PublicBaseURL:        "https://gw.example.com",
		DataFile:             filepath.Join(t.TempDir(), "data.json"),
		UpstreamBaseURL:      up.srv.URL,
		UpstreamKeys:         []UpstreamKey{{Name: "k1", Key: "upstream-secret"}},
		DefaultMonthlyQuota:  1000,
		MaxTokensPerRequest:  4096,
		UpstreamTimeoutSec:   30,
		Models:               []string{"deepseek-chat"},
		AllowAnonymous:       true,
		AnonymousDailyTokens: 100000,
		GlobalDailyTokens:    100000,
		RequestsPerMinute:    1000,
	}
	if mutate != nil {
		mutate(cfg)
	}
	cfg.applyDefaults()
	store, err := OpenStore(cfg.DataFile, cfg.DefaultMonthlyQuota)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return buildMux(mustGateway(t, cfg, store)), store, up
}

func chatRequest(remoteAddr string) *http.Request {
	payload := `{"model":"deepseek-chat","stream":true,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(payload))
	req.RemoteAddr = remoteAddr
	return req
}

func TestFreeModeServesWithoutAnyToken(t *testing.T) {
	mux, store, _ := newFreeGateway(t, nil)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.7:5555"))
	if rec.Code != http.StatusOK {
		t.Fatalf("free mode: %d %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "hel") {
		t.Fatalf("stream body %q", rec.Body.String())
	}
	if got := rec.Header().Get("X-DSG-Plan"); got != "free" {
		t.Fatalf("plan header %q", got)
	}

	ipRem, _ := store.GuestSnapshot(ipHash("203.0.113.7"), 100000, 100000)
	if ipRem != 100000-42 {
		t.Fatalf("guest ledger not booked: remaining=%d", ipRem)
	}
}

func TestFreeModeStillEnforcesPerIPTokenBudget(t *testing.T) {
	mux, _, _ := newFreeGateway(t, func(c *Config) {
		c.AnonymousDailyTokens = 5
	})

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("198.51.100.1:1000")) // books 42 tokens > 5 budget
	if rec.Code != http.StatusOK {
		t.Fatalf("first request: %d %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("198.51.100.1:1001"))
	if rec.Code != http.StatusPaymentRequired {
		t.Fatalf("second request: %d want 402 (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "free_quota_exceeded") {
		t.Fatalf("body %s", rec.Body.String())
	}

	// A different IP still has its own budget.
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("198.51.100.2:1002"))
	if rec.Code != http.StatusOK {
		t.Fatalf("other ip: %d %s", rec.Code, rec.Body.String())
	}
}

func TestFreeModeSiteWideCapProtectsOperatorsKey(t *testing.T) {
	mux, _, _ := newFreeGateway(t, func(c *Config) {
		c.GlobalDailyTokens = 10
	})

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("192.0.2.10:2000"))
	if rec.Code != http.StatusOK {
		t.Fatalf("first: %d %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("192.0.2.11:2001"))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("site cap: %d want 429 (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "global_budget_exhausted") {
		t.Fatalf("body %s", rec.Body.String())
	}
}

func TestFreeModeCanBeTurnedOff(t *testing.T) {
	mux, _, _ := newFreeGateway(t, func(c *Config) { c.AllowAnonymous = false })

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.9:9999"))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d want 401", rec.Code)
	}
}

func TestRateLimitPerMinute(t *testing.T) {
	mux, _, _ := newFreeGateway(t, func(c *Config) { c.RequestsPerMinute = 1 })

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.20:1000"))
	if rec.Code != http.StatusOK {
		t.Fatalf("first: %d %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, chatRequest("203.0.113.20:1001"))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("rate limit: %d want 429", rec.Code)
	}
}

func TestInviteLinkForFreeAndTokenModes(t *testing.T) {
	mux, _, _ := newFreeGateway(t, nil)

	// Free mode: link carries no token at all.
	req := httptest.NewRequest(http.MethodPost, "/admin/invite", strings.NewReader(`{"name":"公益网关"}`))
	req.Header.Set("X-Admin-Token", testAdmin)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("invite: %d %s", rec.Code, rec.Body.String())
	}
	var freeResp struct {
		Link  string `json:"link"`
		Mode  string `json:"mode"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &freeResp); err != nil {
		t.Fatal(err)
	}
	if freeResp.Mode != "free" || freeResp.Token != "" {
		t.Fatalf("unexpected free invite: %+v", freeResp)
	}
	if !strings.HasPrefix(freeResp.Link, "deepseekgo://setup?") ||
		!strings.Contains(freeResp.Link, "base=https%3A%2F%2Fgw.example.com%2Fv1") ||
		strings.Contains(freeResp.Link, "key=") {
		t.Fatalf("bad free link: %s", freeResp.Link)
	}

	// Token mode: link carries an issued dsg_ token.
	req = httptest.NewRequest(http.MethodPost, "/admin/invite", strings.NewReader(`{"plan":"pro.monthly","name":"内部测试"}`))
	req.Header.Set("X-Admin-Token", testAdmin)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("token invite: %d %s", rec.Code, rec.Body.String())
	}
	var tokResp struct {
		Link string `json:"link"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &tokResp)
	if !strings.Contains(tokResp.Link, "key=dsg_") {
		t.Fatalf("token link missing key: %s", tokResp.Link)
	}
}
