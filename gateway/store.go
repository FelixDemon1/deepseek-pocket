package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const quotaPeriod = 30 * 24 * time.Hour

var (
	ErrTokenInvalid  = errors.New("网关令牌无效或已被禁用")
	ErrQuotaExceeded = errors.New("本月额度已用尽")
	ErrUserNotFound  = errors.New("用户不存在")
)

// User is one paying subscriber. The gateway never stores the plaintext token.
type User struct {
	ID           string    `json:"id"`
	TokenHash    string    `json:"token_hash"`
	Plan         string    `json:"plan"`
	Enabled      bool      `json:"enabled"`
	MonthlyQuota int64     `json:"monthly_quota"` // <0 means unlimited
	Used         int64     `json:"used"`
	PeriodStart  time.Time `json:"period_start"`
	CreatedAt    time.Time `json:"created_at"`
	LastSeen     time.Time `json:"last_seen"`
	Note         string    `json:"note,omitempty"`
}

func (u *User) Remaining() int64 {
	if u.MonthlyQuota < 0 {
		return -1
	}
	r := u.MonthlyQuota - u.Used
	if r < 0 {
		return 0
	}
	return r
}

// guestEntry is the free-mode daily ledger for one IP (or for the whole site).
type guestEntry struct {
	Day  string `json:"day"`
	Used int64  `json:"used"`
}

func todayKey() string { return time.Now().UTC().Format("2006-01-02") }

type persistedState struct {
	Users       map[string]*User       `json:"users"`
	Guests      map[string]*guestEntry `json:"guests"`
	Global      *guestEntry            `json:"global"`
	Credentials map[string]*Credential `json:"credentials,omitempty"`
}

type Store struct {
	mu          sync.Mutex
	path        string
	defQuota    int64
	users       map[string]*User
	guests      map[string]*guestEntry
	global      guestEntry
	credentials map[string]*Credential
}

func OpenStore(path string, defaultQuota int64) (*Store, error) {
	s := &Store{
		path:        path,
		defQuota:    defaultQuota,
		users:       map[string]*User{},
		guests:      map[string]*guestEntry{},
		credentials: map[string]*Credential{},
	}
	raw, err := os.ReadFile(path)
	switch {
	case err == nil:
		var st persistedState
		if err := json.Unmarshal(raw, &st); err != nil {
			return nil, fmt.Errorf("解析数据文件 %s: %w", path, err)
		}
		if st.Users != nil {
			s.users = st.Users
		}
		if st.Guests != nil {
			s.guests = st.Guests
		}
		if st.Global != nil {
			s.global = *st.Global
		}
		if st.Credentials != nil {
			s.credentials = st.Credentials
		}
	case errors.Is(err, os.ErrNotExist):
		if err := s.saveLocked(); err != nil {
			return nil, err
		}
	default:
		return nil, err
	}
	return s, nil
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func newToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return "dsg_" + base64.RawURLEncoding.EncodeToString(buf), nil
}

func newUserID() (string, error) {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return "u_" + hex.EncodeToString(buf), nil
}

// CreateUser issues a token. The plaintext token is returned exactly once.
func (s *Store) CreateUser(note, plan string, quota int64) (*User, string, error) {
	token, err := newToken()
	if err != nil {
		return nil, "", err
	}
	id, err := newUserID()
	if err != nil {
		return nil, "", err
	}
	if plan == "" {
		plan = "starter"
	}
	if quota == 0 {
		quota = s.defQuota
	}
	now := time.Now().UTC()
	u := &User{
		ID:           id,
		TokenHash:    hashToken(token),
		Plan:         plan,
		Enabled:      true,
		MonthlyQuota: quota,
		PeriodStart:  now,
		CreatedAt:    now,
		Note:         strings.TrimSpace(note),
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.users[u.ID] = u
	if err := s.saveLocked(); err != nil {
		delete(s.users, u.ID)
		return nil, "", err
	}
	return u, token, nil
}

func (s *Store) resetIfNeededLocked(u *User) {
	now := time.Now().UTC()
	if u.PeriodStart.IsZero() || now.Sub(u.PeriodStart) >= quotaPeriod {
		u.PeriodStart = now
		u.Used = 0
	}
}

// Authenticate resolves a bearer token to a live user (quota period rolled over).
func (s *Store) Authenticate(token string) (*User, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, ErrTokenInvalid
	}
	want := hashToken(token)

	s.mu.Lock()
	defer s.mu.Unlock()
	var found *User
	for _, u := range s.users {
		if u.TokenHash == want {
			found = u
			break
		}
	}
	if found == nil || !found.Enabled {
		return nil, ErrTokenInvalid
	}
	s.resetIfNeededLocked(found)
	found.LastSeen = time.Now().UTC()
	snapshot := *found
	return &snapshot, nil
}

// Snapshot returns a copy of a user (for /v1/me).
func (s *Store) Snapshot(id string) (*User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return nil, ErrUserNotFound
	}
	s.resetIfNeededLocked(u)
	snapshot := *u
	return &snapshot, nil
}

// Reserve rejects the request up-front when the monthly quota is already spent.
func (s *Store) Reserve(id string) (*User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok || !u.Enabled {
		return nil, ErrTokenInvalid
	}
	s.resetIfNeededLocked(u)
	if u.MonthlyQuota >= 0 && u.Used >= u.MonthlyQuota {
		snapshot := *u
		return &snapshot, ErrQuotaExceeded
	}
	snapshot := *u
	return &snapshot, nil
}

// Consume books the tokens actually used by a completed turn.
func (s *Store) Consume(id string, tokens int64) {
	if tokens <= 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return
	}
	u.Used += tokens
	u.LastSeen = time.Now().UTC()
	_ = s.saveLocked()
}

func (s *Store) List() []*User {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*User, 0, len(s.users))
	for _, u := range s.users {
		s.resetIfNeededLocked(u)
		cp := *u
		out = append(out, &cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

func (s *Store) SetEnabled(id string, enabled bool) (*User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return nil, ErrUserNotFound
	}
	u.Enabled = enabled
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	cp := *u
	return &cp, nil
}

// TopUp adds quota (negative delta allowed for corrections, clamped at zero).
func (s *Store) TopUp(id string, delta int64) (*User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return nil, ErrUserNotFound
	}
	u.MonthlyQuota += delta
	if u.MonthlyQuota < 0 && delta >= 0 {
		u.MonthlyQuota = -1
	}
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	cp := *u
	return &cp, nil
}

func (s *Store) saveLocked() error {
	st := persistedState{Users: s.users, Guests: s.guests, Global: &s.global, Credentials: s.credentials}
	raw, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.path)
	if dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	tmp, err := os.CreateTemp(dir, ".data-*.json")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, s.path)
}

// ---------- free (anonymous) mode ledger ----------

var (
	ErrGuestBudget  = errors.New("本 IP 今日免费额度已用尽，明日 00:00 UTC 重置")
	ErrGlobalBudget = errors.New("全站今日免费额度已用尽，明日 00:00 UTC 重置")
)

// ReserveGuest checks both the per-IP and the site-wide daily budget.
// A negative cap means unlimited.
func (s *Store) ReserveGuest(ipHash string, perIP, global int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	day := todayKey()
	if s.global.Day != day {
		s.global = guestEntry{Day: day}
	}
	e := s.guests[ipHash]
	if e == nil {
		e = &guestEntry{Day: day}
		s.guests[ipHash] = e
	}
	if e.Day != day {
		*e = guestEntry{Day: day}
	}
	if global >= 0 && s.global.Used >= global {
		return ErrGlobalBudget
	}
	if perIP >= 0 && e.Used >= perIP {
		return ErrGuestBudget
	}
	return nil
}

// ConsumeGuest books tokens against both ledgers.
func (s *Store) ConsumeGuest(ipHash string, tokens, perIP, global int64) {
	if tokens <= 0 || ipHash == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	day := todayKey()
	if s.global.Day != day {
		s.global = guestEntry{Day: day}
	}
	s.global.Used += tokens
	e := s.guests[ipHash]
	if e == nil || e.Day != day {
		e = &guestEntry{Day: day}
		s.guests[ipHash] = e
	}
	e.Used += tokens
	_ = s.saveLocked()
}

// GuestSnapshot reports remaining free budget for /v1/me.
func (s *Store) GuestSnapshot(ipHash string, perIP, global int64) (ipRemaining, globalRemaining int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	day := todayKey()
	ipUsed, globalUsed := int64(0), int64(0)
	if e, ok := s.guests[ipHash]; ok && e.Day == day {
		ipUsed = e.Used
	}
	if s.global.Day == day {
		globalUsed = s.global.Used
	}
	ipRemaining, globalRemaining = -1, -1
	if perIP >= 0 {
		ipRemaining = max64(0, perIP-ipUsed)
	}
	if global >= 0 {
		globalRemaining = max64(0, global-globalUsed)
	}
	return
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
