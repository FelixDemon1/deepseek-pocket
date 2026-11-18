# DeepSeek Go Gateway

自建 OpenAI 兼容网关：**用你自己的上游 Key，免费开放给你的用户**。
iOS 端零改动接入，支持**一键配置**（`deepseekgo://setup` 深链 / 扫码）。

```
iOS App ──(无令牌 或 Bearer dsg_xxx)──▶ gateway ──Bearer sk-你自己的key──▶ api.deepseek.com
                                          │
                                          ├─ 公益模式：per-IP 日额度 + 全站日总额度 + 每分钟限速
                                          ├─ 令牌模式：用户台账 / 月度额度
                                          ├─ 密钥池轮转，429/401 自动冷却
                                          └─ 首页一键接入页 + 邀请深链
```

## 30 秒上线

```bash
cd gateway
./deploy.sh          # 首次会生成 config.json 并打印管理令牌
$EDITOR config.json  # 填 upstream_keys 的 sk-、改 public_base_url
./deploy.sh          # docker compose up -d --build
```

用户只需要打开 `https://你的域名/`，**扫码**或点**「一键接入本网关」** —— App 直接写入网关地址和令牌，自动探测模型，不用手打任何东西。

二维码由 `./scripts/make-qr.sh` 生成到 `data/qr.png`（deploy.sh 会自动调用），首页自动展示。

## 两种模式

### 公益/免费模式（推荐，`allow_anonymous: true`）

- 用户**不填任何 Key**，打开 App 就能用。
- 三道闸保护你自己的账户：`anonymous_daily_tokens`（每 IP 每日）、`global_daily_tokens`（全站每日）、`requests_per_minute`（每 IP 每分钟请求数）。
- 按 IP 的 SHA-256 前 8 字节记账，不存明文 IP。
- 额度用尽返回 `402 free_quota_exceeded`，全站用尽返回 `429 global_budget_exhausted`，次日 00:00 UTC 自动重置。

### 令牌模式（`allow_anonymous: false` 或显式发令牌）

- `POST /admin/invite` 签发 `dsg_` 令牌 + 深链，适合内部测试或 VIP。
- 月度额度 30 天滚动，`-1` 为不限。


## 自带账号模式（BYOA）

用户不想自己申请 Key 时，可以**用他自己的账号**跑：他把自己的 session 凭据交给网关，
网关只在他本人发起的请求里使用他本人的凭据。**账号之间物理隔离，没有账号池、没有共享。**

```
用户 POST /account/link  {cookie/token}
        ↓ AES-256-GCM 加密落盘（按身份派生 key，明文永不出站、永不回显）
用户 POST /v1/chat/completions  + header X-DSG-Provider: account
        ↓ 用他本人的凭据调上游 → 适配成标准 OpenAI SSE
```

### 配置

```json
"byoa": { "enabled": true, "encryption_key": "至少32字符随机串", "spec_path": "./spec.json" }
```

`spec.json`（见 `spec.example.json`）声明上游长什么样 —— **路径必须来自你自己抓到的
流量，这里不猜任何第三方的私有接口**：

| 字段 | 说明 |
| --- | --- |
| `chat_url` / `method` | 上游对话接口 |
| `headers` | 支持 `{{cookie}}` `{{token}}` 占位符 |
| `body_template` | 支持 `{{model}}` `{{prompt}}` `{{messages_json}}` |
| `response_mode` | `sse_openai` 直通 / `sse_text` 逐段抽取 / `json_text` 一次性 |
| `stream_path` / `response_path` | 从上游响应里取文本的点号路径 |

### 安全边界（写进代码的，不是口号）

- 凭据按 `user:<id>` 或 `ip:<hash>` 派生存储键，**A 的凭据永远不会被 B 用到**（有测试覆盖）。
- 明文只存在于单次请求内存里；`/account/status` 只回 `linked/label/updated_at`。
- 未关联账号时返回 `409 account_not_linked`，**不会悄悄降级去用运维者的 key**。
- `DELETE /account/link` 立即销毁。

### 为什么不做"无限制模式"

没有凭据来源的"无限制"，只能是拿别人的额度。免费发出去 = 让所有用户共用一个不属于你的账号，
上游一封全部同时失效，而且这个失效是不可控、不可恢复的。BYOA 是唯一能"一键"又不炸的形态：
用户自己的号、自己的额度、只给自己用。

## 一键配置链路

网关注入的深链格式：

```
deepseekgo://setup?base=https%3A%2F%2Fgw.example.com%2Fv1&model=deepseek-chat&name=公益网关
```

App 侧 `SetupLink.parse` 解析后：写入 Keychain → 更新 provider config → 自动调用 `/v1/models` 探测。支持的别名：`base`/`base_url`/`endpoint`、`key`/`api_key`/`token`、`dshgo://config`。

一条命令给某个用户单独发链接：

```bash
curl -s -X POST http://127.0.0.1:8787/admin/invite \
  -H "X-Admin-Token: $ADMIN" \
  -d '{"plan":"pro.lifetime","name":"内部测试"}'
# {"link":"deepseekgo://setup?...&key=dsg_...","mode":"token"}
```

## 配置

| 字段 | 说明 |
| --- | --- |
| `listen` / `data_file` | 监听地址；台账落盘路径（原子写：临时文件 → fsync → rename） |
| `admin_token` | 管理令牌，≥16 字符 |
| `public_base_url` | 对外域名，用于生成深链；为空则回退 `http://listen` |
| `upstream_base_url` | 上游 OpenAI 兼容地址 |
| `upstream_keys` | 你自己的上游密钥数组，自动轮转 |
| `allow_anonymous` | 公益模式开关 |
| `anonymous_daily_tokens` | 每 IP 每日免费 token 数，`-1` 不限（默认 50000） |
| `global_daily_tokens` | 全站每日总额度，`-1` 不限（默认 2000000） |
| `requests_per_minute` | 每 IP 每分钟请求数（默认 20） |
| `default_monthly_quota` | 令牌用户默认月额度 |
| `max_tokens_per_request` | 单请求上限，超出自动 clamp |
| `models` | `/v1/models` 返回的模型清单 |

## 接口

用户侧（令牌可省）

- `GET /` — 一键接入落地页
- `POST /v1/chat/completions` — SSE 透传，自动注入 `stream_options.include_usage`
- `GET /v1/models` · `GET /v1/me`

管理侧（`X-Admin-Token`）

- `POST /admin/invite` — 深链（免费模式不带令牌 / 令牌模式现场签发）
- `POST /admin/users` · `GET /admin/users` · `POST /admin/topup` · `POST /admin/toggle`
- `GET /healthz`

## 反向代理

网关信任 `X-Forwarded-For` / `X-Real-IP`，**必须**挂在一层会覆盖这两个头的反代后面，否则客户端可以伪造 IP 绕过 per-IP 额度：

```
gw.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

## 测试

```bash
go test ./...   # 12 项：认证 / 402 额度 / 流式计量 / 429 故障转移 / 分片 usage /
                #        公益模式免令牌 / per-IP 上限 / 全站上限 / 限速 / 深链编码
go vet ./... && gofmt -l .
```
