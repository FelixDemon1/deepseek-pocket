package main

import (
	"errors"
	"net/http"
	"sync"
	"time"
)

// maxRateLimitCooldown caps the linear 429 back-off so a key that was hammered
// for a while comes back within minutes instead of hours.
const maxRateLimitCooldown = 5 * time.Minute

type keyState struct {
	Name      string
	Key       string
	CoolUntil time.Time
	Failures  int
}

// UpstreamPool rotates the operator's own upstream credentials and parks a key
// that the upstream rejected, so one bad key never takes the service down.
type UpstreamPool struct {
	mu      sync.Mutex
	keys    []*keyState
	next    int
	baseURL string
}

func NewUpstreamPool(cfg *Config) *UpstreamPool {
	keys := make([]*keyState, 0, len(cfg.UpstreamKeys))
	for _, k := range cfg.UpstreamKeys {
		keys = append(keys, &keyState{Name: k.Name, Key: k.Key})
	}
	return &UpstreamPool{keys: keys, baseURL: cfg.UpstreamBaseURL}
}

func (p *UpstreamPool) BaseURL() string { return p.baseURL }

func (p *UpstreamPool) Acquire() (*keyState, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	n := len(p.keys)
	for i := 0; i < n; i++ {
		idx := (p.next + i) % n
		k := p.keys[idx]
		if k.CoolUntil.After(now) {
			continue
		}
		p.next = (idx + 1) % n
		return &keyState{Name: k.Name, Key: k.Key}, nil
	}
	return nil, errors.New("所有上游密钥均在冷却中")
}

func (p *UpstreamPool) Report(keyName string, status int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, k := range p.keys {
		if k.Name != keyName {
			continue
		}
		switch {
		case status == http.StatusTooManyRequests:
			k.Failures++
			k.CoolUntil = time.Now().Add(min(time.Duration(30*k.Failures)*time.Second, maxRateLimitCooldown))
		case status == http.StatusUnauthorized || status == http.StatusForbidden:
			k.Failures++
			k.CoolUntil = time.Now().Add(10 * time.Minute)
		case status >= 500:
			k.Failures++
			k.CoolUntil = time.Now().Add(15 * time.Second)
		default:
			k.Failures = 0
			k.CoolUntil = time.Time{}
		}
		return
	}
}

func (p *UpstreamPool) Healthy() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	n := 0
	for _, k := range p.keys {
		if !k.CoolUntil.After(now) {
			n++
		}
	}
	return n
}
