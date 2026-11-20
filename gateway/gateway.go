package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const maxRequestBody = 8 << 20 // 8 MiB

type Gateway struct {
	cfg     *Config
	store   *Store
	pool    *UpstreamPool
	http    *http.Client
	limiter *rateLimiter
	vault   *credentialVault
	spec    *AdapterSpec
}

func NewGateway(cfg *Config, store *Store, pool *UpstreamPool) (*Gateway, error) {
	g := &Gateway{
		cfg:     cfg,
		store:   store,
		pool:    pool,
		limiter: newRateLimiter(cfg.RequestsPerMinute),
		http:    newUpstreamClient(time.Duration(cfg.UpstreamTimeoutSec) * time.Second),
	}
	if cfg.BYOA.Enabled {
		vault, err := newCredentialVault(cfg.BYOA.EncryptionKey)
		if err != nil {
			return nil, err
		}
		spec, err := LoadAdapterSpec(cfg.BYOA.SpecPath)
		if err != nil {
			return nil, err
		}
		g.vault, g.spec = vault, spec
		log.Printf("BYOA 已启用：adapter=%s mode=%s models=%v", spec.Name, spec.ResponseMode, spec.Models)
	}
	return g, nil
}

// newUpstreamClient bounds connecting and waiting for response headers, but not
// the body: an SSE turn (long R1 reasoning) may legitimately stream for many
// minutes and is torn down when the client disconnects (request context).
// Buffered (non-stream) calls get an explicit deadline in handleChatCompletions.
func newUpstreamClient(headerTimeout time.Duration) *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			DialContext:           (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			TLSHandshakeTimeout:   15 * time.Second,
			ResponseHeaderTimeout: headerTimeout,
			IdleConnTimeout:       90 * time.Second,
			MaxIdleConnsPerHost:   16,
			ForceAttemptHTTP2:     true,
		},
	}
}

// ---------- identity ----------

type identity struct {
	userID    string
	ipHash    string
	isGuest   bool
	plan      string
	remaining int64
}

func (i *identity) book(store *Store, tokens int64, perIP, global int64) {
	if tokens <= 0 {
		return
	}
	if i.isGuest {
		store.ConsumeGuest(i.ipHash, tokens, perIP, global)
		return
	}
	store.Consume(i.userID, tokens)
}

type httpError struct {
	status int
	kind   string
	msg    string
}

func (e *httpError) Error() string { return e.msg }

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if h == "" {
		return ""
	}
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return strings.TrimSpace(h)
}

// clientIP honours X-Forwarded-For (set by Caddy/Nginx) and falls back to the socket.
// It takes the right-most entry: that one is appended by our own reverse proxy,
// whereas everything to its left is client-controlled and trivially spoofed to
// dodge the per-IP free budget.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			if ip := strings.TrimSpace(parts[i]); ip != "" {
				return ip
			}
		}
	}
	if rip := r.Header.Get("X-Real-IP"); rip != "" {
		return strings.TrimSpace(rip)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func ipHash(ip string) string {
	sum := sha256.Sum256([]byte(ip))
	return hex.EncodeToString(sum[:8])
}

// resolve maps a metered request (one that spends tokens) to either a paid token
// holder or an anonymous free user, enforcing RPM and budgets.
func (g *Gateway) resolve(r *http.Request) (*identity, *httpError) {
	return g.identify(r, true)
}

// peek identifies the caller for read-only endpoints (/v1/models, /v1/me,
// /account/status): it neither burns the per-minute allowance nor rejects an
// exhausted budget, so the app can still show "0 remaining" instead of an error.
func (g *Gateway) peek(r *http.Request) (*identity, *httpError) {
	return g.identify(r, false)
}

func (g *Gateway) identify(r *http.Request, metered bool) (*identity, *httpError) {
	token := bearerToken(r)
	if token != "" {
		user, err := g.store.Authenticate(token)
		if err != nil {
			return nil, &httpError{http.StatusUnauthorized, "invalid_token", err.Error()}
		}
		if !metered {
			return &identity{userID: user.ID, plan: user.Plan, remaining: user.Remaining()}, nil
		}
		reserved, rerr := g.store.Reserve(user.ID)
		if errors.Is(rerr, ErrQuotaExceeded) {
			return nil, &httpError{http.StatusPaymentRequired, "quota_exceeded",
				"本月额度已用尽，请续订或提升套餐额度"}
		}
		if rerr != nil {
			return nil, &httpError{http.StatusUnauthorized, "invalid_token", rerr.Error()}
		}
		return &identity{userID: user.ID, plan: user.Plan, remaining: reserved.Remaining()}, nil
	}

	if !g.cfg.AllowAnonymous {
		return nil, &httpError{http.StatusUnauthorized, "invalid_token", "缺少 Bearer 令牌"}
	}

	hash := ipHash(clientIP(r))
	if !metered {
		ipRem, _ := g.store.GuestSnapshot(hash, g.cfg.AnonymousDailyTokens, g.cfg.GlobalDailyTokens)
		return &identity{ipHash: hash, isGuest: true, plan: "free", remaining: ipRem}, nil
	}
	if !g.limiter.Allow(hash) {
		return nil, &httpError{http.StatusTooManyRequests, "rate_limited",
			fmt.Sprintf("请求过于频繁，上限 %d 次/分钟", g.cfg.RequestsPerMinute)}
	}
	switch err := g.store.ReserveGuest(hash, g.cfg.AnonymousDailyTokens, g.cfg.GlobalDailyTokens); {
	case errors.Is(err, ErrGlobalBudget):
		return nil, &httpError{http.StatusTooManyRequests, "global_budget_exhausted", err.Error()}
	case errors.Is(err, ErrGuestBudget):
		return nil, &httpError{http.StatusPaymentRequired, "free_quota_exceeded", err.Error()}
	}
	ipRem, _ := g.store.GuestSnapshot(hash, g.cfg.AnonymousDailyTokens, g.cfg.GlobalDailyTokens)
	return &identity{ipHash: hash, isGuest: true, plan: "free", remaining: ipRem}, nil
}

// ---------- helpers ----------

// publicUser strips the token hash before a user record leaves the process.
func publicUser(u *User) map[string]any {
	return map[string]any{
		"id":              u.ID,
		"plan":            u.Plan,
		"enabled":         u.Enabled,
		"monthly_quota":   u.MonthlyQuota,
		"used":            u.Used,
		"remaining":       u.Remaining(),
		"period_start":    u.PeriodStart,
		"period_reset_at": u.PeriodStart.Add(quotaPeriod),
		"created_at":      u.CreatedAt,
		"note":            u.Note,
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeAPIError(w http.ResponseWriter, status int, kind, msg string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]any{"message": msg, "type": kind, "status": status},
	})
}

// ---------- public API ----------

func (g *Gateway) handleModels(w http.ResponseWriter, r *http.Request) {
	ident, herr := g.peek(r)
	if herr != nil {
		writeAPIError(w, herr.status, herr.kind, herr.msg)
		return
	}
	data := make([]map[string]any, 0, len(g.cfg.Models))
	for _, m := range g.cfg.Models {
		data = append(data, map[string]any{
			"id":       m,
			"object":   "model",
			"owned_by": "deepseek-go-gateway",
		})
	}
	w.Header().Set("X-DSG-Plan", ident.plan)
	writeJSON(w, http.StatusOK, map[string]any{"object": "list", "data": data})
}

func (g *Gateway) handleMe(w http.ResponseWriter, r *http.Request) {
	ident, herr := g.peek(r)
	if herr != nil {
		writeAPIError(w, herr.status, herr.kind, herr.msg)
		return
	}
	if ident.isGuest {
		ipRem, globalRem := g.store.GuestSnapshot(ident.ipHash, g.cfg.AnonymousDailyTokens, g.cfg.GlobalDailyTokens)
		writeJSON(w, http.StatusOK, map[string]any{
			"plan":           "free",
			"remaining":      ipRem,
			"daily_quota":    g.cfg.AnonymousDailyTokens,
			"site_remaining": globalRem,
			"reset_hint":     "每日 00:00 UTC 重置",
		})
		return
	}
	user, err := g.store.Snapshot(ident.userID)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":              user.ID,
		"plan":            user.Plan,
		"monthly_quota":   user.MonthlyQuota,
		"used":            user.Used,
		"remaining":       user.Remaining(),
		"period_start":    user.PeriodStart,
		"period_reset_at": user.PeriodStart.Add(quotaPeriod),
	})
}

func (g *Gateway) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	ident, herr := g.resolve(r)
	if herr != nil {
		writeAPIError(w, herr.status, herr.kind, herr.msg)
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequestBody))
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "请求体读取失败")
		return
	}

	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "请求体不是合法 JSON")
		return
	}

	stream, _ := payload["stream"].(bool)
	payload["stream"] = stream
	if stream {
		opts, _ := payload["stream_options"].(map[string]any)
		if opts == nil {
			opts = map[string]any{}
		}
		opts["include_usage"] = true
		payload["stream_options"] = opts
	}
	if mt, ok := payload["max_tokens"].(float64); ok && int(mt) > g.cfg.MaxTokensPerRequest {
		payload["max_tokens"] = g.cfg.MaxTokensPerRequest
	}
	if _, ok := payload["model"].(string); !ok {
		payload["model"] = g.cfg.Models[0]
	}

	forwarded, err := json.Marshal(payload)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "请求体序列化失败")
		return
	}

	if wantsOwnAccount(r, payload) {
		g.chatViaAccount(w, r, ident, payload, stream)
		return
	}

	ctx := r.Context()
	if !stream {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(g.cfg.UpstreamTimeoutSec)*time.Second)
		defer cancel()
	}
	resp, keyName, fail := g.dialUpstream(ctx, forwarded)
	if fail != nil {
		writeAPIError(w, fail.status, "upstream_error", fail.msg)
		return
	}
	defer resp.Body.Close()

	if stream {
		g.streamThrough(w, r, resp, ident, keyName)
		return
	}
	g.bufferThrough(w, resp, ident, keyName)
}

// upstreamFailure is what the *client* sees. Upstream key names and raw upstream
// bodies stay in the server log only.
type upstreamFailure struct {
	status int
	msg    string
}

func (g *Gateway) dialUpstream(ctx context.Context, body []byte) (*http.Response, string, *upstreamFailure) {
	attempts := len(g.cfg.UpstreamKeys)
	var fail *upstreamFailure
	for i := 0; i < attempts; i++ {
		key, err := g.pool.Acquire()
		if err != nil {
			if fail != nil {
				return nil, "", fail
			}
			log.Printf("upstream: %v", err)
			return nil, "", &upstreamFailure{http.StatusServiceUnavailable, "上游模型服务暂时不可用，请稍后重试"}
		}
		target := g.pool.BaseURL() + "/chat/completions"
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(body))
		if err != nil {
			return nil, "", &upstreamFailure{http.StatusInternalServerError, "构造上游请求失败"}
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "text/event-stream")
		req.Header.Set("Authorization", "Bearer "+key.Key)

		resp, err := g.http.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil, "", &upstreamFailure{http.StatusGatewayTimeout, "上游响应超时，请稍后重试"}
			}
			g.pool.Report(key.Name, http.StatusInternalServerError)
			log.Printf("upstream %s dial error: %v", key.Name, err)
			fail = &upstreamFailure{http.StatusBadGateway, "上游模型服务暂时不可用，请稍后重试"}
			continue
		}
		if resp.StatusCode == http.StatusOK {
			g.pool.Report(key.Name, http.StatusOK)
			return resp, key.Name, nil
		}
		g.pool.Report(key.Name, resp.StatusCode)
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		log.Printf("upstream %s HTTP %d: %s", key.Name, resp.StatusCode, strings.TrimSpace(string(detail)))
		switch {
		case resp.StatusCode == http.StatusTooManyRequests:
			fail = &upstreamFailure{http.StatusServiceUnavailable, "上游模型服务繁忙，请稍后重试"}
		case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
			fail = &upstreamFailure{http.StatusBadGateway, "网关上游密钥异常，请联系运维者"}
		case resp.StatusCode >= 500:
			fail = &upstreamFailure{http.StatusBadGateway, "上游模型服务暂时不可用，请稍后重试"}
		default:
			// 400 / 404 / 422 etc. are the caller's own mistake (bad model id, bad
			// params): pass the status and upstream's human message through.
			return nil, "", &upstreamFailure{resp.StatusCode, upstreamMessage(detail, resp.StatusCode)}
		}
	}
	if fail == nil {
		fail = &upstreamFailure{http.StatusBadGateway, "上游不可用"}
	}
	return nil, "", fail
}

// upstreamMessage extracts `error.message` from an OpenAI-style error body.
func upstreamMessage(raw []byte, status int) string {
	var parsed struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(raw, &parsed) == nil && strings.TrimSpace(parsed.Error.Message) != "" {
		msg := strings.TrimSpace(parsed.Error.Message)
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return msg
	}
	return fmt.Sprintf("上游拒绝了请求（HTTP %d）", status)
}

func (g *Gateway) streamThrough(w http.ResponseWriter, r *http.Request, resp *http.Response, ident *identity, keyName string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeAPIError(w, http.StatusInternalServerError, "server_error", "响应流不支持 flush")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("X-DSG-Plan", ident.plan)
	w.Header().Set("X-DSG-Quota-Remaining", fmt.Sprint(ident.remaining))
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	sniffer := &usageSniffer{}
	var outputBytes int64
	buf := make([]byte, 16*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			flusher.Flush()
			sniffer.Feed(buf[:n])
			outputBytes += int64(n)
		}
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, context.Canceled) {
				log.Printf("stream read error user=%s guest=%v: %v", ident.userID, ident.isGuest, err)
			}
			break
		}
		if r.Context().Err() != nil {
			break
		}
	}

	used := sniffer.Total()
	if used == 0 {
		used = outputBytes / 4 // conservative fallback when upstream omits usage
	}
	ident.book(g.store, used, g.cfg.AnonymousDailyTokens, g.cfg.GlobalDailyTokens)
}

func (g *Gateway) bufferThrough(w http.ResponseWriter, resp *http.Response, ident *identity, keyName string) {
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, "upstream_error", "上游响应读取失败")
		return
	}
	var parsed struct {
		Usage *usagePayload `json:"usage"`
	}
	used := int64(0)
	if json.Unmarshal(raw, &parsed) == nil && parsed.Usage != nil && parsed.Usage.TotalTokens > 0 {
		used = int64(parsed.Usage.TotalTokens)
	} else {
		used = int64(len(raw) / 4)
	}
	ident.book(g.store, used, g.cfg.AnonymousDailyTokens, g.cfg.GlobalDailyTokens)

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-DSG-Plan", ident.plan)
	w.Header().Set("X-DSG-Quota-Remaining", fmt.Sprint(ident.remaining))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

// ---------- admin API ----------

func (g *Gateway) adminAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("X-Admin-Token")
		if subtle.ConstantTimeCompare([]byte(got), []byte(g.cfg.AdminToken)) != 1 {
			writeAPIError(w, http.StatusUnauthorized, "invalid_admin", "管理令牌无效")
			return
		}
		next(w, r)
	}
}

func (g *Gateway) handleAdminCreateUser(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Note  string `json:"note"`
		Plan  string `json:"plan"`
		Quota int64  `json:"monthly_quota"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "请求体解析失败")
		return
	}
	applyPlanQuota(req.Plan, &req.Quota)
	user, token, err := g.store.CreateUser(req.Note, req.Plan, req.Quota)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, "store_error", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"user":  publicUser(user),
		"token": token,
		"hint":  "令牌仅此一次返回，请写入 iOS 端「自定义网关」的 API Key 字段",
		"link":  g.inviteLink(token, g.cfg.Models[0], "自建网关"),
	})
}

func applyPlanQuota(plan string, quota *int64) {
	switch strings.ToLower(plan) {
	case "pro.monthly", "pro.lifetime", "unlimited":
		if *quota == 0 {
			*quota = -1
		}
	}
}

// inviteLink builds the one-tap onboarding URL (deepseekgo://setup?…) that any
// DeepSeek Go build opens directly into a working configuration.
func (g *Gateway) inviteLink(token, model, name string) string {
	base := g.cfg.PublicBaseURL
	if base == "" {
		base = "http://" + g.cfg.Listen
	}
	if !strings.HasSuffix(base, "/v1") {
		base += "/v1"
	}
	u := url.URL{Scheme: "deepseekgo", Host: "setup"}
	q := url.Values{}
	q.Set("base", base)
	q.Set("model", model)
	q.Set("name", name)
	if token != "" {
		q.Set("key", token)
	}
	u.RawQuery = q.Encode()
	return u.String()
}

func (g *Gateway) handleAdminListUsers(w http.ResponseWriter, r *http.Request) {
	users := g.store.List()
	out := make([]map[string]any, 0, len(users))
	for _, u := range users {
		out = append(out, publicUser(u))
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": out})
}

func (g *Gateway) handleAdminTopUp(w http.ResponseWriter, r *http.Request) {
	var req struct {
		UserID string `json:"user_id"`
		Delta  int64  `json:"delta"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "请求体解析失败")
		return
	}
	user, err := g.store.TopUp(req.UserID, req.Delta)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"user": publicUser(user)})
}

func (g *Gateway) handleAdminToggle(w http.ResponseWriter, r *http.Request) {
	var req struct {
		UserID  string `json:"user_id"`
		Enabled bool   `json:"enabled"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "请求体解析失败")
		return
	}
	user, err := g.store.SetEnabled(req.UserID, req.Enabled)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"user": publicUser(user)})
}

// handleAdminInvite mints a shareable one-tap link. In free mode the link carries
// no token at all, so it can be printed on a landing page or a QR code.
func (g *Gateway) handleAdminInvite(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Note  string `json:"note"`
		Plan  string `json:"plan"`
		Model string `json:"model"`
		Name  string `json:"name"`
	}
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req)
	if req.Model == "" {
		req.Model = g.cfg.Models[0]
	}
	if req.Name == "" {
		req.Name = "自建网关"
	}

	if strings.EqualFold(req.Plan, "anonymous") || (req.Plan == "" && g.cfg.AllowAnonymous) {
		writeJSON(w, http.StatusOK, map[string]any{
			"token": "",
			"link":  g.inviteLink("", req.Model, req.Name),
			"mode":  "free",
		})
		return
	}

	var quota int64
	applyPlanQuota(req.Plan, &quota)
	user, token, err := g.store.CreateUser(req.Note, req.Plan, quota)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, "store_error", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"user":  publicUser(user),
		"token": token,
		"link":  g.inviteLink(token, req.Model, req.Name),
		"mode":  "token",
	})
}

func (g *Gateway) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "ok",
		"healthy_keys": g.pool.Healthy(),
		"total_keys":   len(g.cfg.UpstreamKeys),
		"users":        len(g.store.List()),
		"upstream":     g.pool.BaseURL(),
		"free_mode":    g.cfg.AllowAnonymous,
		"daily_global": g.cfg.GlobalDailyTokens,
	})
}

// ---------- per-IP rate limiter ----------

type rateLimiter struct {
	mu    sync.Mutex
	limit int
	hits  map[string]*rlEntry
}

type rlEntry struct {
	window time.Time
	count  int
}

func newRateLimiter(limit int) *rateLimiter {
	return &rateLimiter{limit: limit, hits: map[string]*rlEntry{}}
}

func (l *rateLimiter) Allow(key string) bool {
	if l.limit <= 0 {
		return true
	}
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.hits) > 10000 {
		for k, v := range l.hits {
			if now.Sub(v.window) > 2*time.Minute {
				delete(l.hits, k)
			}
		}
	}
	e, ok := l.hits[key]
	if !ok || now.Sub(e.window) >= time.Minute {
		l.hits[key] = &rlEntry{window: now, count: 1}
		return true
	}
	if e.count >= l.limit {
		return false
	}
	e.count++
	return true
}

// ---------- SSE usage sniffer ----------

type usageSniffer struct {
	remainder []byte
	total     int64
	seen      bool
}

func (s *usageSniffer) Feed(p []byte) {
	s.remainder = append(s.remainder, p...)
	for {
		i := bytes.IndexByte(s.remainder, '\n')
		if i < 0 {
			break
		}
		s.scanLine(s.remainder[:i])
		s.remainder = s.remainder[i+1:]
	}
	if len(s.remainder) > 1<<20 {
		s.remainder = append([]byte{}, s.remainder[len(s.remainder)-(1<<19):]...)
	}
}

func (s *usageSniffer) scanLine(line []byte) {
	line = bytes.TrimSpace(line)
	if !bytes.HasPrefix(line, []byte("data:")) {
		return
	}
	payload := bytes.TrimSpace(line[len("data:"):])
	if len(payload) == 0 || bytes.Equal(payload, []byte("[DONE]")) {
		return
	}
	if !bytes.Contains(payload, []byte(`"usage"`)) {
		return
	}
	var obj struct {
		Usage *usagePayload `json:"usage"`
	}
	if err := json.Unmarshal(payload, &obj); err != nil || obj.Usage == nil {
		return
	}
	if obj.Usage.TotalTokens > 0 {
		s.total = int64(obj.Usage.TotalTokens)
		s.seen = true
	}
}

func (s *usageSniffer) Total() int64 {
	if !s.seen {
		return 0
	}
	return s.total
}

type usagePayload struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// ---------- one-tap landing page ----------

// qrPath is where deploy.sh drops the rendered QR for the current invite link.
func (g *Gateway) qrPath() string {
	return filepath.Join(filepath.Dir(g.cfg.DataFile), "qr.png")
}

func (g *Gateway) handleQR(w http.ResponseWriter, r *http.Request) {
	path := g.qrPath()
	if _, err := os.Stat(path); err != nil {
		writeAPIError(w, http.StatusNotFound, "no_qr", "尚未生成二维码：运行 ./deploy.sh 或 scripts/make-qr.sh")
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeFile(w, r, path)
}

// handleLanding serves the operator's public page: one button that opens the app
// already configured, plus a QR for people reading on a desktop.
func (g *Gateway) handleLanding(w http.ResponseWriter, r *http.Request) {
	link := g.inviteLink("", g.cfg.Models[0], "公益网关")
	qrBlock := ""
	if _, err := os.Stat(g.qrPath()); err == nil {
		qrBlock = `<img src="/qr.png" alt="扫码接入" width="200" height="200" style="margin:0 auto 18px;border-radius:12px">`
	}
	mode := "本网关当前需要邀请令牌"
	if g.cfg.AllowAnonymous {
		mode = "免费开放中 · 无需令牌 · 每 IP 每日 " + humanTokens(g.cfg.AnonymousDailyTokens)
	}
	page := `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DeepSeek Go · 一键接入</title>
<style>
:root{color-scheme:light dark}
body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;
display:flex;min-height:100vh;align-items:center;justify-content:center;
background:#fff;color:#0f172a}
@media(prefers-color-scheme:dark){body{background:#0b1020;color:#e6ecff}
.card{background:#151b2e!important;border-color:#26304a!important}
.btn{background:#4D6BFE!important;color:#fff!important}}
.card{max-width:420px;padding:32px 28px;border:1px solid #e6eaf2;border-radius:20px;
box-shadow:0 12px 40px rgba(77,107,254,.10);text-align:center}
h1{font-size:22px;margin:0 0 8px}
p{color:#64748b;margin:0 0 24px;font-size:14px}
.btn{display:block;padding:15px;border-radius:14px;background:#4D6BFE;color:#fff;
text-decoration:none;font-weight:600;letter-spacing:.02em}
code{display:block;margin-top:18px;font-size:11px;word-break:break-all;color:#94a3b8}
</style></head><body><div class="card">
<h1>DeepSeek Go</h1>
<p>` + mode + `</p>
` + qrBlock + `<a class="btn" href="` + link + `">一键接入本网关</a>
<code>` + link + `</code>
</div></body></html>`
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = io.WriteString(w, page)
}

func humanTokens(n int64) string {
	switch {
	case n < 0:
		return "不限额"
	case n >= 1000000:
		return fmt.Sprintf("%.1fM tokens", float64(n)/1000000)
	case n >= 1000:
		return fmt.Sprintf("%.0fK tokens", float64(n)/1000)
	default:
		return fmt.Sprintf("%d tokens", n)
	}
}
