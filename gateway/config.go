package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

// UpstreamKey is one credential that the operator owns (their own paid DeepSeek /
// OpenRouter / SiliconFlow account). The gateway never accepts upstream credentials
// from end users — it only accepts its own issued gateway tokens.
type UpstreamKey struct {
	Name string `json:"name"`
	Key  string `json:"key"`
}

type Config struct {
	Listen              string        `json:"listen"`
	AdminToken          string        `json:"admin_token"`
	DataFile            string        `json:"data_file"`
	UpstreamBaseURL     string        `json:"upstream_base_url"`
	UpstreamKeys        []UpstreamKey `json:"upstream_keys"`
	DefaultMonthlyQuota int64         `json:"default_monthly_quota"`
	MaxTokensPerRequest int           `json:"max_tokens_per_request"`
	UpstreamTimeoutSec  int           `json:"upstream_timeout_seconds"`
	Models              []string      `json:"models"`

	// 公开公益模式：不收费、不发票，任何装了 App 的人都能直接连。
	// 靠 per-IP 日额度 + 全站日总额度 + 每分钟请求数三道闸，防止单个用户把
	// 运维者自己的上游 key 刷爆。
	PublicBaseURL        string `json:"public_base_url"`
	AllowAnonymous       bool   `json:"allow_anonymous"`
	AnonymousDailyTokens int64  `json:"anonymous_daily_tokens"`
	GlobalDailyTokens    int64  `json:"global_daily_tokens"`
	RequestsPerMinute    int    `json:"requests_per_minute"`

	// 自带账号模式（BYOA）：每个用户用他本人的账号凭据，凭据加密落盘、按身份隔离。
	BYOA BYOAConfig `json:"byoa"`
}

type BYOAConfig struct {
	Enabled       bool   `json:"enabled"`
	EncryptionKey string `json:"encryption_key"`
	SpecPath      string `json:"spec_path"`
}

func (c *Config) applyDefaults() {
	if c.Listen == "" {
		c.Listen = "127.0.0.1:8787"
	}
	if c.DataFile == "" {
		c.DataFile = "data.json"
	}
	if c.UpstreamBaseURL == "" {
		c.UpstreamBaseURL = "https://api.deepseek.com/v1"
	}
	if c.MaxTokensPerRequest <= 0 {
		c.MaxTokensPerRequest = 8192
	}
	if c.UpstreamTimeoutSec <= 0 {
		c.UpstreamTimeoutSec = 300
	}
	if c.AnonymousDailyTokens == 0 {
		c.AnonymousDailyTokens = 50000
	}
	if c.GlobalDailyTokens == 0 {
		c.GlobalDailyTokens = 2000000
	}
	if c.RequestsPerMinute <= 0 {
		c.RequestsPerMinute = 20
	}
	c.PublicBaseURL = strings.TrimRight(c.PublicBaseURL, "/")
	if len(c.Models) == 0 {
		c.Models = []string{"deepseek-chat", "deepseek-reasoner"}
	}
	c.UpstreamBaseURL = strings.TrimRight(c.UpstreamBaseURL, "/")
}

func (c *Config) validate() error {
	if len(c.AdminToken) < 16 {
		return errors.New("admin_token 至少 16 个字符")
	}
	if len(c.UpstreamKeys) == 0 {
		return errors.New("upstream_keys 至少需要一个自有上游密钥")
	}
	for i, k := range c.UpstreamKeys {
		if strings.TrimSpace(k.Key) == "" {
			return fmt.Errorf("upstream_keys[%d].key 为空", i)
		}
		if k.Name == "" {
			c.UpstreamKeys[i].Name = fmt.Sprintf("key-%d", i+1)
		}
	}
	return nil
}

func LoadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取配置 %s: %w", path, err)
	}
	var c Config
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("解析配置 %s: %w", path, err)
	}
	c.applyDefaults()
	if err := c.validate(); err != nil {
		return nil, err
	}
	return &c, nil
}
