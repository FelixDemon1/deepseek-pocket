package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// BYOA — Bring Your Own Account.
//
// 用户把自己的账号凭据（session cookie / token）交给网关，网关只在他自己发起
// 请求时使用他本人的凭据，绝不跨用户复用、绝不做账号池。凭据以 AES-256-GCM
// 加密后落盘，任何接口都不会回显明文。
//
// 上游长什么样由 AdapterSpec 声明（chat_url / headers / body_template /
// response_mode），所以这里不猜测任何第三方私有路径 —— 路径由使用者从自己
// 抓到的流量里填。
// ---------------------------------------------------------------------------

type AdapterSpec struct {
	Name         string            `json:"name"`
	ChatURL      string            `json:"chat_url"`
	Method       string            `json:"method"`
	Headers      map[string]string `json:"headers"`
	BodyTemplate string            `json:"body_template"`
	ResponseMode string            `json:"response_mode"` // sse_openai | sse_text | json_text
	ResponsePath string            `json:"response_path"` // json_text 用
	StreamPath   string            `json:"stream_path"`   // sse_text 用
	Models       []string          `json:"models"`
}

func LoadAdapterSpec(path string) (*AdapterSpec, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取 adapter spec %s: %w", path, err)
	}
	var s AdapterSpec
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("解析 adapter spec: %w", err)
	}
	if s.Method == "" {
		s.Method = http.MethodPost
	}
	if s.ResponseMode == "" {
		s.ResponseMode = "sse_openai"
	}
	switch s.ResponseMode {
	case "sse_openai", "sse_text", "json_text":
	default:
		return nil, fmt.Errorf("未知 response_mode: %s", s.ResponseMode)
	}
	if s.ChatURL == "" {
		return nil, errors.New("adapter spec 缺少 chat_url")
	}
	return &s, nil
}

// ---------- credential vault ----------

type Credential struct {
	UserKey   string    `json:"user_key"`
	Blob      string    `json:"blob"`
	Label     string    `json:"label"`
	UpdatedAt time.Time `json:"updated_at"`
}

type credentialVault struct {
	aead cipher.AEAD
}

func newCredentialVault(secret string) (*credentialVault, error) {
	if strings.TrimSpace(secret) == "" {
		return nil, errors.New("byoa.encryption_key 为空：请设置为至少 32 字符的随机串")
	}
	if len(secret) < 32 {
		return nil, errors.New("byoa.encryption_key 至少 32 字符")
	}
	sum := sha256.Sum256([]byte(secret))
	block, err := aes.NewCipher(sum[:])
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &credentialVault{aead: aead}, nil
}

func (v *credentialVault) seal(plain []byte) (string, error) {
	nonce := make([]byte, v.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := v.aead.Seal(nonce, nonce, plain, nil)
	return base64.StdEncoding.EncodeToString(sealed), nil
}

func (v *credentialVault) open(blob string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(blob)
	if err != nil {
		return nil, err
	}
	size := v.aead.NonceSize()
	if len(raw) < size {
		return nil, errors.New("凭据密文损坏")
	}
	return v.aead.Open(nil, raw[:size], raw[size:], nil)
}

// credentialKey binds a credential to exactly one identity: a gateway user, or —
// in free mode — one client IP. Two callers can never share a credential.
func credentialKey(ident *identity) string {
	if ident.isGuest {
		return "ip:" + ident.ipHash
	}
	return "user:" + ident.userID
}

// ---------- store ----------

func (s *Store) SetCredential(userKey, blob, label string) (*Credential, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.credentials == nil {
		s.credentials = map[string]*Credential{}
	}
	c := &Credential{UserKey: userKey, Blob: blob, Label: label, UpdatedAt: time.Now().UTC()}
	s.credentials[userKey] = c
	if err := s.saveLocked(); err != nil {
		delete(s.credentials, userKey)
		return nil, err
	}
	cp := *c
	return &cp, nil
}

func (s *Store) GetCredential(userKey string) (*Credential, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.credentials[userKey]
	if !ok {
		return nil, false
	}
	cp := *c
	return &cp, true
}

func (s *Store) DeleteCredential(userKey string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.credentials[userKey]; !ok {
		return false
	}
	delete(s.credentials, userKey)
	_ = s.saveLocked()
	return true
}

// ---------- linking endpoints ----------

func (g *Gateway) handleAccountStatus(w http.ResponseWriter, r *http.Request) {
	ident, herr := g.resolve(r)
	if herr != nil {
		writeAPIError(w, herr.status, herr.kind, herr.msg)
		return
	}
	if g.vault == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "byoa_disabled", "本网关未启用自带账号模式")
		return
	}
	cred, ok := g.store.GetCredential(credentialKey(ident))
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"linked": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"linked":     true,
		"label":      cred.Label,
		"updated_at": cred.UpdatedAt,
		// 明文凭据永不出站
	})
}

func (g *Gateway) handleAccountLink(w http.ResponseWriter, r *http.Request) {
	ident, herr := g.resolve(r)
	if herr != nil {
		writeAPIError(w, herr.status, herr.kind, herr.msg)
		return
	}
	if g.vault == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "byoa_disabled", "本网关未启用自带账号模式")
		return
	}
	var req struct {
		Label  string            `json:"label"`
		Creds  map[string]string `json:"credentials"`
		Cookie string            `json:"cookie"`
		Token  string            `json:"token"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "请求体解析失败")
		return
	}
	creds := req.Creds
	if creds == nil {
		creds = map[string]string{}
	}
	if req.Cookie != "" {
		creds["cookie"] = req.Cookie
	}
	if req.Token != "" {
		creds["token"] = req.Token
	}
	if len(creds) == 0 {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "credentials 为空")
		return
	}

	plain, err := json.Marshal(creds)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, "server_error", "凭据序列化失败")
		return
	}
	blob, err := g.vault.seal(plain)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, "server_error", "凭据加密失败")
		return
	}
	label := req.Label
	if label == "" {
		label = "我的账号"
	}
	cred, err := g.store.SetCredential(credentialKey(ident), blob, label)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, "store_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"linked":     true,
		"label":      cred.Label,
		"updated_at": cred.UpdatedAt,
	})
}

func (g *Gateway) handleAccountUnlink(w http.ResponseWriter, r *http.Request) {
	ident, herr := g.resolve(r)
	if herr != nil {
		writeAPIError(w, herr.status, herr.kind, herr.msg)
		return
	}
	removed := g.store.DeleteCredential(credentialKey(ident))
	writeJSON(w, http.StatusOK, map[string]any{"unlinked": removed})
}

// ---------- own-account inference ----------

func (g *Gateway) chatViaAccount(w http.ResponseWriter, r *http.Request, ident *identity, payload map[string]any, stream bool) {
	if g.vault == nil || g.spec == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "byoa_disabled", "本网关未启用自带账号模式")
		return
	}
	cred, ok := g.store.GetCredential(credentialKey(ident))
	if !ok {
		writeAPIError(w, http.StatusConflict, "account_not_linked",
			"还没有关联你自己的账号：先调用 POST /account/link 或在接入页扫码登录")
		return
	}
	plain, err := g.vault.open(cred.Blob)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, "vault_error", "凭据解密失败，请重新关联账号")
		return
	}
	var creds map[string]string
	if err := json.Unmarshal(plain, &creds); err != nil {
		writeAPIError(w, http.StatusInternalServerError, "vault_error", "凭据格式损坏")
		return
	}

	model, _ := payload["model"].(string)
	prompt := lastUserPrompt(payload)

	upReq, err := g.buildAdapterRequest(creds, model, prompt, payload)
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, "adapter_error", err.Error())
		return
	}
	resp, err := g.http.Do(upReq.WithContext(r.Context()))
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, "upstream_error", err.Error())
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		writeAPIError(w, http.StatusBadGateway, "upstream_error",
			fmt.Sprintf("你自己的账号侧返回 HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(detail))))
		return
	}

	switch g.spec.ResponseMode {
	case "json_text":
		g.adaptJSONText(w, resp, ident, model)
	case "sse_text":
		g.adaptSSEText(w, r, resp, ident, model, stream)
	default:
		g.streamThrough(w, r, resp, ident, "own-account")
	}
}

func lastUserPrompt(payload map[string]any) string {
	msgs, _ := payload["messages"].([]any)
	for i := len(msgs) - 1; i >= 0; i-- {
		m, _ := msgs[i].(map[string]any)
		if m == nil {
			continue
		}
		if role, _ := m["role"].(string); role != "user" {
			continue
		}
		if content, ok := m["content"].(string); ok {
			return content
		}
	}
	return ""
}

func (g *Gateway) buildAdapterRequest(creds map[string]string, model, prompt string, payload map[string]any) (*http.Request, error) {
	vars := map[string]string{
		"model":  model,
		"prompt": prompt,
	}
	for k, v := range creds {
		vars[k] = v
	}
	if raw, err := json.Marshal(payload["messages"]); err == nil {
		vars["messages_json"] = string(raw)
	}

	body := renderTemplate(g.spec.BodyTemplate, vars, true)
	req, err := http.NewRequest(g.spec.Method, g.spec.ChatURL, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	for k, v := range g.spec.Headers {
		req.Header.Set(k, renderTemplate(v, vars, false))
	}
	if req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "text/event-stream")
	return req, nil
}

// renderTemplate substitutes {{name}} placeholders. JSON mode escapes values so a
// credential containing quotes can never break the request body.
func renderTemplate(tpl string, vars map[string]string, jsonEscape bool) string {
	out := tpl
	for k, v := range vars {
		if jsonEscape {
			b, _ := json.Marshal(v)
			escaped := string(b)
			if len(escaped) >= 2 {
				escaped = escaped[1 : len(escaped)-1]
			}
			out = strings.ReplaceAll(out, "{{"+k+"}}", escaped)
			continue
		}
		out = strings.ReplaceAll(out, "{{"+k+"}}", v)
	}
	return out
}

// dig walks a dotted path ("data.answer", "choices.0.delta.content").
func dig(raw []byte, path string) (string, bool) {
	if path == "" {
		return "", false
	}
	var cur any
	if err := json.Unmarshal(raw, &cur); err != nil {
		return "", false
	}
	for _, part := range strings.Split(path, ".") {
		switch node := cur.(type) {
		case map[string]any:
			next, ok := node[part]
			if !ok {
				return "", false
			}
			cur = next
		case []any:
			idx, err := strconv.Atoi(part)
			if err != nil || idx < 0 || idx >= len(node) {
				return "", false
			}
			cur = node[idx]
		default:
			return "", false
		}
	}
	if s, ok := cur.(string); ok {
		return s, true
	}
	return "", false
}

// ---------- response adapters ----------

func (g *Gateway) adaptJSONText(w http.ResponseWriter, resp *http.Response, ident *identity, model string) {
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, "upstream_error", "读取上游响应失败")
		return
	}
	text, ok := dig(raw, g.spec.ResponsePath)
	if !ok {
		writeAPIError(w, http.StatusBadGateway, "adapter_error",
			"response_path 未命中，检查 spec 里的 response_path")
		return
	}
	used := int64(len([]rune(text)))/4 + 1
	ident.book(g.store, used, g.cfg.AnonymousDailyTokens, g.cfg.GlobalDailyTokens)

	writeJSON(w, http.StatusOK, map[string]any{
		"id":      "chatcmpl-own-" + strconv.FormatInt(time.Now().UnixNano(), 36),
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   model,
		"choices": []map[string]any{{
			"index":         0,
			"message":       map[string]any{"role": "assistant", "content": text},
			"finish_reason": "stop",
		}},
		"usage": map[string]any{
			"prompt_tokens": 0, "completion_tokens": used, "total_tokens": used,
		},
	})
}

func (g *Gateway) adaptSSEText(w http.ResponseWriter, r *http.Request, resp *http.Response, ident *identity, model string, stream bool) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeAPIError(w, http.StatusInternalServerError, "server_error", "响应流不支持 flush")
		return
	}

	var collected strings.Builder
	emit := func(text string) bool {
		if text == "" {
			return true
		}
		collected.WriteString(text)
		if !stream {
			return true
		}
		chunk := map[string]any{
			"id":      "chatcmpl-own-" + strconv.FormatInt(time.Now().UnixNano(), 36),
			"object":  "chat.completion.chunk",
			"created": time.Now().Unix(),
			"model":   model,
			"choices": []map[string]any{{
				"index":         0,
				"delta":         map[string]any{"content": text},
				"finish_reason": nil,
			}},
		}
		b, _ := json.Marshal(chunk)
		if _, err := fmt.Fprintf(w, "data: %s\n\n", b); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}

	if stream {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache, no-transform")
		w.Header().Set("X-Accel-Buffering", "no")
		w.Header().Set("X-DSG-Plan", ident.plan)
		w.WriteHeader(http.StatusOK)
		flusher.Flush()
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 4<<20)
	for scanner.Scan() {
		if r.Context().Err() != nil {
			break
		}
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		if text, ok := dig([]byte(payload), g.spec.StreamPath); ok {
			if !emit(text) {
				break
			}
		}
	}

	text := collected.String()
	used := int64(len([]rune(text)))/4 + 1
	ident.book(g.store, used, g.cfg.AnonymousDailyTokens, g.cfg.GlobalDailyTokens)

	if !stream {
		writeJSON(w, http.StatusOK, map[string]any{
			"id":      "chatcmpl-own-" + strconv.FormatInt(time.Now().UnixNano(), 36),
			"object":  "chat.completion",
			"created": time.Now().Unix(),
			"model":   model,
			"choices": []map[string]any{{
				"index":         0,
				"message":       map[string]any{"role": "assistant", "content": text},
				"finish_reason": "stop",
			}},
			"usage": map[string]any{"prompt_tokens": 0, "completion_tokens": used, "total_tokens": used},
		})
		return
	}

	usageChunk, _ := json.Marshal(map[string]any{
		"id":      "chatcmpl-own-usage",
		"object":  "chat.completion.chunk",
		"created": time.Now().Unix(),
		"model":   model,
		"choices": []any{},
		"usage":   map[string]any{"prompt_tokens": 0, "completion_tokens": used, "total_tokens": used},
	})
	_, _ = fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n", usageChunk)
	flusher.Flush()
}

// wantsOwnAccount reports whether the caller asked to use their own credentials.
func wantsOwnAccount(r *http.Request, payload map[string]any) bool {
	if v, _ := payload["provider"].(string); strings.EqualFold(v, "account") {
		return true
	}
	if v, _ := payload["provider"].(string); strings.EqualFold(v, "own") {
		return true
	}
	return strings.EqualFold(r.Header.Get("X-DSG-Provider"), "account")
}
