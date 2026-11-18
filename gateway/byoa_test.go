package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeAccountUpstream stands in for "the user's own account backend": it only
// answers when the caller presents the credential the user linked.
type fakeAccountUpstream struct {
	srv        *httptest.Server
	wantCookie string
	lastCookie string
	hits       int
}

func newFakeAccountUpstream(t *testing.T, mode string) *fakeAccountUpstream {
	t.Helper()
	f := &fakeAccountUpstream{wantCookie: "sid=user-own-session"}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.hits++
		f.lastCookie = r.Header.Get("Cookie")
		if !strings.Contains(f.lastCookie, "sid=user-own-session") {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"error":"not logged in"}`)
			return
		}
		if mode == "json_text" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"data":{"answer":"你好，我是你自己的账号"}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fl := w.(http.Flusher)
		for _, piece := range []string{"你", "好", "呀"} {
			_, _ = io.WriteString(w, `data: {"data":{"text":"`+piece+`"}}`+"\n\n")
			fl.Flush()
		}
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
		fl.Flush()
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func newBYOAGateway(t *testing.T, mode string) (http.Handler, *Store, *fakeAccountUpstream) {
	t.Helper()
	up := newFakeAccountUpstream(t, mode)

	path := filepath.Join(t.TempDir(), "spec.json")
	spec := AdapterSpec{
		Name:         "own-account",
		ChatURL:      up.srv.URL + "/api/chat",
		Method:       http.MethodPost,
		Headers:      map[string]string{"Cookie": "{{cookie}}", "Content-Type": "application/json"},
		BodyTemplate: `{"model":"{{model}}","messages":{{messages_json}}}`,
		ResponseMode: mode,
		ResponsePath: "data.answer",
		StreamPath:   "data.text",
		Models:       []string{"own-model"},
	}
	raw, _ := json.Marshal(spec)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := &Config{
		Listen:              "127.0.0.1:0",
		AdminToken:          testAdmin,
		DataFile:            filepath.Join(t.TempDir(), "data.json"),
		UpstreamBaseURL:     up.srv.URL,
		UpstreamKeys:        []UpstreamKey{{Name: "k1", Key: "operator-key"}},
		DefaultMonthlyQuota: 100000,
		MaxTokensPerRequest: 4096,
		UpstreamTimeoutSec:  30,
		Models:              []string{"own-model"},
		BYOA: BYOAConfig{
			Enabled:       true,
			EncryptionKey: "0123456789abcdef0123456789abcdef",
			SpecPath:      path,
		},
	}
	cfg.applyDefaults()
	store, err := OpenStore(cfg.DataFile, cfg.DefaultMonthlyQuota)
	if err != nil {
		t.Fatal(err)
	}
	return buildMux(mustGateway(t, cfg, store)), store, up
}

func TestOwnAccountLinkingAndStreaming(t *testing.T) {
	mux, _, up := newBYOAGateway(t, "sse_text")
	_, token, _ := muxUser(mux, t)

	// 1. Not linked yet -> clear 409 instead of silently using the operator key.
	req := ownChatRequest(token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("unlinked: %d want 409 (%s)", rec.Code, rec.Body.String())
	}
	if up.hits != 0 {
		t.Fatalf("must not touch upstream before linking")
	}

	// 2. Link the user's own session.
	linkReq := httptest.NewRequest(http.MethodPost, "/account/link",
		strings.NewReader(`{"label":"我的号","cookie":"sid=user-own-session; other=1"}`))
	linkReq.Header.Set("Authorization", "Bearer "+token)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, linkReq)
	if rec.Code != http.StatusOK {
		t.Fatalf("link: %d %s", rec.Code, rec.Body.String())
	}

	// 3. Status reports linked but never echoes the secret.
	rec = httptest.NewRecorder()
	statusReq := httptest.NewRequest(http.MethodGet, "/account/status", nil)
	statusReq.Header.Set("Authorization", "Bearer "+token)
	mux.ServeHTTP(rec, statusReq)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"linked":true`) {
		t.Fatalf("status: %d %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "user-own-session") {
		t.Fatalf("status leaked the credential: %s", rec.Body.String())
	}

	// 4. Chat through the user's own account, adapted to OpenAI SSE.
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, ownChatRequest(token))
	if rec.Code != http.StatusOK {
		t.Fatalf("own chat: %d %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	for _, want := range []string{`"content":"你"`, `"content":"好"`, `"content":"呀"`, "[DONE]"} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %s in %q", want, body)
		}
	}
	if !strings.Contains(up.lastCookie, "user-own-session") {
		t.Fatalf("upstream did not receive the user's credential: %q", up.lastCookie)
	}
}

func TestOwnAccountIsIsolatedPerUser(t *testing.T) {
	mux, _, up := newBYOAGateway(t, "sse_text")
	_, aliceToken, _ := muxUser(mux, t)
	_, bobToken, _ := muxUser(mux, t)

	linkReq := httptest.NewRequest(http.MethodPost, "/account/link",
		strings.NewReader(`{"cookie":"sid=user-own-session"}`))
	linkReq.Header.Set("Authorization", "Bearer "+aliceToken)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, linkReq)
	if rec.Code != http.StatusOK {
		t.Fatalf("alice link: %d %s", rec.Code, rec.Body.String())
	}

	// Bob never linked anything: he must not inherit Alice's credential.
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, ownChatRequest(bobToken))
	if rec.Code != http.StatusConflict {
		t.Fatalf("bob: %d want 409 (%s)", rec.Code, rec.Body.String())
	}
	if up.hits != 0 {
		t.Fatalf("bob's request reached the upstream using someone else's creds")
	}
}

func TestOwnAccountJSONMode(t *testing.T) {
	mux, _, _ := newBYOAGateway(t, "json_text")
	_, token, _ := muxUser(mux, t)

	linkReq := httptest.NewRequest(http.MethodPost, "/account/link",
		strings.NewReader(`{"cookie":"sid=user-own-session"}`))
	linkReq.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, linkReq)

	payload := `{"model":"own-model","provider":"account","stream":false,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+token)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("json mode: %d %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "你好，我是你自己的账号") {
		t.Fatalf("body %s", rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"object":"chat.completion"`) {
		t.Fatalf("not OpenAI shaped: %s", rec.Body.String())
	}
}

func TestCredentialIsEncryptedAtRest(t *testing.T) {
	_, store, _ := newBYOAGateway(t, "sse_text")
	vault, err := newCredentialVault("0123456789abcdef0123456789abcdef")
	if err != nil {
		t.Fatal(err)
	}
	blob, err := vault.seal([]byte(`{"cookie":"sid=user-own-session"}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.SetCredential("user:u_test", blob, "test"); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "user-own-session") {
		t.Fatalf("plaintext credential found on disk: %s", raw)
	}

	cred, ok := store.GetCredential("user:u_test")
	if !ok {
		t.Fatal("credential missing")
	}
	plain, err := vault.open(cred.Blob)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(plain), "user-own-session") {
		t.Fatalf("round-trip failed: %s", plain)
	}

	// Wrong key must not decrypt.
	other, _ := newCredentialVault("ffffffffffffffffffffffffffffffff")
	if _, err := other.open(cred.Blob); err == nil {
		t.Fatal("decrypted with the wrong key")
	}
}

func TestTemplateRenderingEscapesCredentials(t *testing.T) {
	got := renderTemplate(`{"c":"{{cookie}}"}`,
		map[string]string{"cookie": `a"b\c`}, true)
	if got != `{"c":"a\"b\\c"}` {
		t.Fatalf("bad escape: %s", got)
	}
	if raw := renderTemplate("Cookie: {{cookie}}", map[string]string{"cookie": `a"b`}, false); raw != `Cookie: a"b` {
		t.Fatalf("header should not be escaped: %s", raw)
	}
}

// ---------- helpers ----------

func muxUser(mux http.Handler, t *testing.T) (string, string, error) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/admin/users", strings.NewReader(`{"plan":"pro.lifetime"}`))
	req.Header.Set("X-Admin-Token", testAdmin)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create user: %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Token string `json:"token"`
		User  struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out.User.ID, out.Token, nil
}

func ownChatRequest(token string) *http.Request {
	payload := `{"model":"own-model","provider":"account","stream":true,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+token)
	return req
}
