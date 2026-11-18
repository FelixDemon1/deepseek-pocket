# DeepSeek Pocket · 交接文档（HANDOFF）

> 更新：2026-11-19 · 面向接手的 AI 工程师（ChatGPT / Codex / Claude Code）或人类开发者。
> 读完这一页就能接着干；所有命令都在本机实测通过。

---

## 0. 一句话现状

**能编译、能上真机、能聊天。** 三档模式（默认 / 工程 / 无限制·dsh-purge 破甲）、项目化会话、个人资料都已上线；**本轮的真正新增是「手机端反代链路」（Web Adapter）** —— 不依赖桌面网关、不需要 MITM，靠 App 内嵌 WKWebView 登录官方网页版取凭据 + 协议翻译层跑通 DeepSeek / Qwen / 豆包。

**唯一缺口**：三个内置渠道规格还标着 `calibrated: false`，需要一次真实账号的实机校准（拿到真回包后改 JSON 即可，不用改代码）。

---

## 1. 构建 · 测试 · 装机（照抄即可）

```bash
cd /Users/qinzihan/.gemini/antigravity/scratch/deepseek-go-ios

# 单元测试（Swift Testing，不是 XCTest）
cd Packages/DeepSeekKit && swift test          # 期望：25 tests in 3 suites passed
cd ../..

# 真机包
xcodebuild -project DeepSeekGo.xcodeproj -scheme DeepSeekGo \
  -destination 'id=00008150-000A34DA2E63401C' -configuration Debug \
  DEVELOPMENT_TEAM=42A7TP5GH8 PRODUCT_BUNDLE_IDENTIFIER=io.deepseekgo.felix \
  -allowProvisioningUpdates build

# 装机 + 启动
xcrun devicectl device install app --device 1AB8EF63-A612-5FE7-B105-10BC42A5AC4E \
  ~/Library/Developer/Xcode/DerivedData/DeepSeekGo-flfjjdyajaymgnguekyszjwwmzqb/Build/Products/Debug-iphoneos/DeepSeekGo.app
xcrun devicectl device process launch --device 1AB8EF63-A612-5FE7-B105-10BC42A5AC4E io.deepseekgo.felix
```

- 设备：iPhone 17 Pro Max，**iOS 26.3.0**，真实 UDID `1AB8EF63-A612-5FE7-B105-10BC42A5AC4E`
- 团队：`42A7TP5GH8` —— **免费个人团队**，profile 7 天过期，过期后重跑 build 会自动续签
- 设备锁屏时 install 会报 `BSErrorCodeDescription = Locked`，解锁重试即可
- macOS 上没有 `timeout` 命令；长时间日志用后台 + `sleep` + `pkill`

---

## 2. 目录地图（只列要动的）

```
Packages/DeepSeekKit/Sources/DeepSeekCore/
  Models.swift            ProviderConfig / ChatSession(projectId) / PromptPreset(summary) / WorkspaceProject
  DeepSeekClient.swift    OpenAI 兼容流式客户端 + SSECompletionAssembler
  AgentHarness.swift      多步工具循环、审批门、Mid-Turn Steer
  WorkspaceTools.swift    沙盒文件工具（读写/列举/diff）
  PurgeProfile.swift      无限制模式(dsh-purge 破甲) 与工程模式提示词
  WebAdapterSpec.swift    ★反代：渠道规格 + 3 个内置预设 + 模板渲染 + 点路径
  WebAdapterClient.swift  ★反代：请求翻译 + SSE 反翻译 + WebAdapterTransport + 凭据解析
  CredentialVault.swift   Keychain（WhenUnlockedThisDeviceOnly）
  SandboxLift.swift       worse_query 沙箱越权移植（需 App Group，见 §5）
  SetupLink.swift         deepseekgo://setup 深链（QR / 一键配置）

Packages/DeepSeekKit/Sources/DeepSeekUI/
  RootWorkspaceView.swift      主界面、抽屉、顶部胶囊、sheet 路由
  ConnectAISheet.swift         ★新的「连接 AI」唯一入口
  WebAdapterLoginSheet.swift   ★WKWebView 登录 + 读 localStorage/cookie
  SteerComposerBar.swift       输入框：+ 菜单、深度思考、模式 chip
  SecurityAndWorkspaceSheets.swift  项目/文件/模式选择器
  SettingsAndShareSheets.swift      设置（个人资料 / AI 接口 / 关于）
  AppViewModel.swift           全局状态、持久化、transport 路由
```

---

## 3. ★ 手机端反代链路（本轮重点）

### 3.1 为什么不是 MITM

桌面端 `wb2api` 那套能做，是因为它能读自己进程/磁盘上的会话。iOS 上：

- 读不到别的 App 的 Keychain（keychain access group 隔离）
- 装用户根证书也过不了大厂 App 的证书固定（pinning）
- 没有越狱就没有进程注入

**所以手机端不该做"代理"，该做"翻译"。** 只要协议翻译在我们自己的 App 里，外部反代服务就是多余的：

```
官方网页版  ←─ 登录 ─→  我们自己的 WKWebView（我们自己的 cookie/localStorage）
                              │ 读出 token
                              ▼
                       Keychain（本机、不联网、不上 iCloud）
                              │
   OpenAI 兼容请求 ──→  WebAdapterClient ──→  官网私有接口
                              │
   StreamDelta     ←──  WebDeltaExtractor ←── 官网 SSE
```

合规边界：读的是**本 App 自己这个 webview** 的数据，凭据是用户自己的账号，请求由用户自己发起，不存在代持或账号池。

### 3.2 已实现（有单测覆盖）

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| 渠道规格声明（chat_url / headers / body_template / response_mode / 凭据来源） | `WebAdapterSpec.swift` | ✅ |
| 模板渲染 `{{token}} {{prompt}} {{messages_json}} {{model}}` | `WebAdapterTemplate` | ✅ 含 JSON 安全转义测试 |
| 四种回包翻译：`sse_openai` / `sse_json_text` / `sse_deepseek` / `sse_doubao`，另 `json_text` | `WebDeltaExtractor` | ✅ 单测覆盖补丁式、快照式、thinking 分流 |
| 快照流转增量（豆包那种每次都给全量） | `SnapshotAccumulator` | ✅ |
| 凭据解析（localStorage JSON 取 `.value`、cookie、去 `Bearer ` 前缀） | `WebCredentialParser` | ✅ |
| 接进 Harness（`ModelStreamingTransport`） | `WebAdapterTransport` | ✅ |
| 登录 → 取凭据 → 存 Keychain → 切通道 | `WebAdapterLoginSheet` + `AppViewModel` | ✅ 未实机验证 |
| 通道持久化（重启后仍生效） | `StoredSettings.activeWebAdapterID` | ✅ |

### 3.3 三个内置预设

| 渠道 | 登录页 | 凭据 | 接口 | 回包模式 |
| --- | --- | --- | --- | --- |
| DeepSeek 网页版 | chat.deepseek.com/sign_in | localStorage `userToken` → `.value` | `/api/v0/chat/completion` | `sse_deepseek`（p/o/v 补丁） |
| 通义千问网页版 | chat.qwen.ai | cookie `token` | `/api/v2/chat/completions` | `sse_openai`（`phase:"think"` 走 reasoning） |
| 豆包网页版 | www.doubao.com/chat | cookie `sessionid` | `/samantha/chat/completion` | `sse_doubao`（event_type 2001） |

> **实测记录（2026-11-19）**：从 Mac 直连 `POST https://chat.deepseek.com/api/v0/chat/completion`（假 token）返回
> `HTTP 200 + {"code":40003,"msg":"INVALID_TOKEN"}` —— 说明路径对，但**上游会用 HTTP 200 包错误信封**，
> 客户端必须显式识别，否则会静默返回空回答。`WebAdapterClient.errorEnvelope` 已处理，并会把
> PoW/签名类错误（`MISSING_POW_SIGNATURE`）翻译成"该渠道启用风控签名，先用官方 Key"。
> `POST https://chat.qwen.ai/api/v2/chat/completions`（无头）返回 **405**，预设待校准。

**全部 `calibrated: false`** —— 链路、翻译、凭据解析都有单测，但真实回包格式没在真账号上验过。

### 3.4 校准流程（下一个接手者最该做的事）

1. 用你自己的账号、你自己的设备，在 Mac 上开 Charles / Proxyman，iPhone 挂同一个 Wi-Fi 代理并信任证书（只抓自己设备、自己的流量）
2. 在官方 App/网页里发一句话，抓那条 `completion` 请求
3. 抄三样东西：**URL**、**请求头**（Authorization / Cookie / 特殊头）、**请求体 JSON**
4. 把回包（SSE 每条 `data:`）对应到 `WebResponseMode` 里最接近的一个
5. 在 App 内「连接 AI → ③ 高级 → 粘贴自己的渠道配置（JSON）」导入，把 `calibrated` 改 `true`，若验证 OK 再回写进 `WebAdapterSpec.presets`
6. 有回归就跑 `swift test`

**只改 JSON，不用改代码。**

### 3.5 已知难点（别踩）

- **豆包**要两个随机 UUID（`local_conversation_id` / `local_message_id`），模板里已经用 `{{local_conversation}} {{local_message}}` 注入
- **Qwen** 的 `bx-v` 之类版本头会过期，抓包时要一起抄
- **DeepSeek** 首包是 fragments 快照、后续才是 APPEND 补丁；`WebDeltaExtractor` 已经按「先快照后补丁」处理，若上游改成纯快照，走 `sse_json_text`
- 有的站点 token 带引号或 `Bearer ` 前缀，`WebCredentialParser` 已剥
- 请求体模板必须保持合法 JSON，`makeRequest` 会先 `JSONSerialization` 校验，坏了直接抛 `badSpec`

### 3.6 协议层自适应（用户不需要选）

有的「OpenAI 兼容」网关其实挂在 `/v1/responses`（OpenAI 新接口）而不是 `/v1/chat/completions`。
`ResponsesClient.detectProtocol()` 连接时探一次：先 POST `chat/completions`，404/405 再试 `responses`，
结果写进 `ProviderConfig.flavor`；`AppViewModel.currentTransport()` 据此选客户端。
工具定义会在 Responses 里就地展平（`{type:function,name,parameters}`），回包解析
`response.output_text.delta` / `reasoning_summary_text.delta` / `output_item.done(function_call)`。
**注意**：探测用的 `probe` 模型名一定失败，只要不是 404/405 就算"路由存在"。

---

## 4. UI 现状

- **抽屉**（左）：头像 + 昵称 + 「模式 · 当前项目」→ 「发起新对话」→「对话」（默认工作区）→ 每个项目一节 → 「在此项目中新建对话」 → 底部「管理项目…」。**只有点页外遮罩或拖遮罩才关闭**，面板内滑动全部归还给列表（左滑删除正常）
- **输入框**：`+`（上传文件 / 上传图片）、`深度思考`、**模式 chip**（默认 / 工程 / 无限制，菜单里带推荐场景 + 「模式说明…」）
- **键盘**：滚动 interactively 收起；点空白收；开面板/开 sheet 自动收（`endEditing()` 用 `UIApplication.sendAction(resignFirstResponder)`）
- **个人资料**：昵称 + 头像（默认 App 图标 `AvatarDefault`，可自传，256×256 JPEG 存 UserDefaults）
- **连接 AI**（`ConnectAISheet`）：唯一入口。① 网页版登录（免 Key）② 官方 Key（粘贴 + 立即验证拉模型）③ 高级（自定义地址、粘贴 spec JSON）
- 顶部胶囊点开也进「连接 AI」
- **发送前的拦截条件**（`needsCredentialsBeforeSend`）：网页版通道看有没有凭据；官方域名看有没有 Key；自定义网关一律放行。漏判会导致"点发送却弹出设置面板"——这是曾经的线上 bug

---

## 5. 沙箱越权（worse_query 移植）现状

`SandboxLift.swift` 已完整移植：SPI 加载 → 符号链接 → `container_query_*`(class 7 / part 3) → `sandbox_extension_consume`，另加 `leakDirectories`（fsgetpath inode 枚举）。

**真机实测（iOS 26.3.0，免费团队）结论：**

| 步骤 | 结果 |
| --- | --- |
| SPI `dlopen` | ✅ 成功 |
| App Group 容器 | ❌ `containerURL(forSecurityApplicationGroupIdentifier:)` 返回 nil |
| 建符号链接 | ✅ Library/Documents/tmp 都能建 |
| 替换 `Library/Caches` | ❌ `513 没有权限` |
| `container_query` class 7 | ❌ `-1 container unavailable` |
| class 1 | ❌ `-4 symlink failed` |

**硬前置是 App Group，免费团队签不出来**（`CODE_SIGN_ENTITLEMENTS` 在 pbxproj 里被移除就是这个原因）。付费 $99 或个人团队 + Ad Hoc、或企业证书才有。换团队后要做的唯一动作：把 `App/DeepSeekGo.entitlements` 重新接回 `CODE_SIGN_ENTITLEMENTS`。

自检命令：`--lift-probe` 启动参数 → `SandboxLiftProbe.log()`。

---

## 6. 未完成（按优先级）

**P1｜反代校准（最该做）**：三个预设实机校准 → 把 `calibrated` 改真 → 在 `ConnectAISheet` 里去掉「待校准」角标。

**P1｜免费额度渠道目录**：用户已拍板要内置 **OpenRouter / 硅基流动 / GitHub Models / Groq / 智谱** 五家。做一张静态表（baseURL、免费模型 id、注册外链、一句"坑"），点一下开注册页、回来粘 token 自动配好。注意 Groq / GitHub Models 上没有 DeepSeek 模型，**模型胶囊不能再写死 DeepSeek**，要改成能力档位（快速回答 / 深度思考）。

**P2｜L0 免费通道**：需要人类先部署 `gateway/`（Docker + `deploy.sh` 现成，匿名额度/限速/预算都有）并给一台 VPS。没部署前不要在 UI 里放"免费"按钮，会变成死入口。

**P2｜视觉徽章**：无限制模式生效时在助手气泡挂 `bolt.shield · 无限制`，让 purge 对外可见。

**P3｜模式解锁闸**：用户考虑过"未解锁不能选无限制模式"，已建议不做（假锁 + 多一步流失）。若要恢复，加 `purgeUnlocked: Bool` 灰掉菜单项即可。

---

## 7. 已知坑

1. **测试用 Swift Testing**（`import Testing` / `@Suite` / `@Test` / `#expect`），写 XCTest 类不会被发现，会静默不跑
2. **包同时给 macOS 编译**，所有 UIKit API 必须 `#if canImport(UIKit)`，否则 `swift build` 崩（`Form` 的报错会伪装成 "trailing closure passed to FormStyleConfiguration"）
3. **中文文案里不要用英文双引号**，Swift 字符串会断；用 `“”` 或转义
4. `.onChange(of:)` 在本工程的 macOS 目标上是**零参数**形式，写闭包参数会编译失败
5. `AppViewModel` 里 `#if canImport(UIKit)` 的方法（如 `updateAvatarImage`）在 macOS 目标不存在，调用点也要一起包起来
6. 免费团队每次重签后旧包会失效，装完立刻启动验证
7. `git commit` 不要自作主张 —— 只在用户明确要求时提交

---

## 8. 需要人类决策

1. **L0 免费通道**：自建 gateway（约 10–40 元/月 VPS + 上游 token，按 2 万 token/人/天估 ≈70–200 元/月）还是不提供？
2. **免费额度数值**：建议 2 万 token/天/人
3. **五家外链是否挂邀请/返点码**
4. 未配置时是否允许"先逛后配"（建议允许，发第一条时再拦）

---

## 9. 免责声明位置（已落地）

- `README.md` 顶部：开源 · 仅供技术交流，MIT，与 DeepSeek/Apple 无隶属
- App 内「设置 → 关于」：同文案 + GitHub 链接 + 版本号
- **没有**启动弹窗或首启协议页（刻意不做，丑且无意义）

---

## 10. 一句话给下一个 AI

反代这条链路的**代码骨架已经完整**，剩下的不是编程而是**一次真实抓包校准**：拿到真回包 → 改 `WebAdapterSpec` 的 JSON → `calibrated: true` → 跑 `swift test`。别重写，别退回 MITM 方案。
