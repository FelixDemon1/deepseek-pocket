# DeepSeek Pocket · 工程交接文档（HANDOFF）

> 更新：2026-11-20 · 面向后续接手的 iOS / Go 工程师与编码助手。
> 本文档汇总当前架构、构建测试命令、云端部署结构与待优化的产品体验清单。

---

## 0. 项目现状概览

本项目是一个基于 Swift 6 + SwiftUI 的 iOS 原生 AI 对话与本地工作区客户端（附带一个可选的 Go 语言 OpenAI 兼容网关 `gateway/`）。

- **多渠道接入**：
  1. **内置网页会话适配层（`WebAdapter`）**：用户在 App 自身的 `WKWebView` 中登录个人账号（支持 DeepSeek 网页版、豆包网页版、通义千问国内版 `www.qianwen.com`），由客户端完成请求格式转换与 SSE 流式解析，凭据仅存于本机 Keychain。
  2. **标准 OpenAI 兼容 API Key**：内置 DeepSeek、阿里云百炼（通义千问）、智谱 GLM、硅基流动、Groq、GitHub Models、OpenRouter、月之暗面 Kimi 等厂商目录，支持自动拉取 `/v1/models` 与自由切换模型。
  3. **自建云端网关（`https://app.apifish.me`）**：部署于 Azure Ubuntu 服务器，提供配置同步（`/specs.json`）与带配额限流的 OpenAI 兼容转发服务（`/v1/*`）。
- **核心功能**：三档提示词预设（日常默认 / 工程代码 / 精简直出）、项目文件夹挂载（DocumentPicker 安全书签）、离线图片 OCR、代码/HTML 沙盒预览卡片、实时网络请求审计面板。

---

## 1. 构建 · 测试 · 真机安装 · 云端检查

工作区目录必须设为仓库根目录：`/Users/qinzihan/.gemini/antigravity/scratch/deepseek-go-ios`

```bash
cd /Users/qinzihan/.gemini/antigravity/scratch/deepseek-go-ios

# 1) Swift 核心包单元测试（使用 Swift Testing 框架）
cd Packages/DeepSeekKit && swift test          # 期望：46 tests in 4 suites passed
cd ../..

# 2) Go 网关单元测试
cd gateway && go test ./... && cd ..

# 3) 编译并签名 iOS 真机包
xcodebuild -project DeepSeekGo.xcodeproj -scheme DeepSeekGo \
  -destination 'generic/platform=iOS' -configuration Debug \
  DEVELOPMENT_TEAM=42A7TP5GH8 PRODUCT_BUNDLE_IDENTIFIER=io.deepseekgo.felix \
  -allowProvisioningUpdates build

# 4) 安装到已连接的 iPhone 17 Pro Max 并启动
xcrun devicectl device install app --device 1AB8EF63-A612-5FE7-B105-10BC42A5AC4E \
  ~/Library/Developer/Xcode/DerivedData/DeepSeekGo-flfjjdyajaymgnguekyszjwwmzqb/Build/Products/Debug-iphoneos/DeepSeekGo.app
xcrun devicectl device process launch --device 1AB8EF63-A612-5FE7-B105-10BC42A5AC4E \
  --terminate-existing io.deepseekgo.felix

# 5) 云端健康检查（Azure: <user>@<server-ip>）
curl -sS https://app.apifish.me/healthz
curl -sS https://app.apifish.me/specs.json | head -n 20
```

- **连接设备**：iPhone 17 Pro Max（iOS 26.3.0，UDID `1AB8EF63-A612-5FE7-B105-10BC42A5AC4E`）
- **签名说明**：`42A7TP5GH8` 为个人开发者团队，设备锁屏时 `launch` 会提示 `Locked`，解锁屏幕后重试即可。

---

## 2. 目录结构地图

```text
Packages/DeepSeekKit/Sources/DeepSeekCore/
  Models.swift                数据模型（ProviderConfig / ChatSession / PromptPreset / WorkspaceProject）
  DeepSeekClient.swift        OpenAI chat/completions 流式客户端与 SSE 解析器
  ResponsesClient.swift       OpenAI responses 协议客户端与协议自动探测
  AgentHarness.swift          多步本地工作区工具循环、用户确认门与中途补充指令（Steer）
  WorkspaceTools.swift        应用沙盒与用户授权目录内的文件读写、Diff 与 JavaScriptCore 计算
  PurgeProfile.swift          精简直出预设与工程模式系统提示词
  KeyProviderCatalogue.swift  各厂商 API 地址、默认模型与候选模型列表
  WebAdapterSpec.swift        网页会话适配规格定义、模板渲染与 JSON 点路径工具
  WebAdapterClient.swift      网页会话流式客户端、SSE 增量转换器与哈希计算工具
  CredentialVault.swift       本机 Keychain 凭据存取（WhenUnlockedThisDeviceOnly）
  PrivacyFirewall.swift       出站域名白名单校验与本地联网审计记录
  SetupLink.swift             deepseekgo://setup 一键配置深链解析

Packages/DeepSeekKit/Sources/DeepSeekUI/
  AppViewModel.swift               全局状态管理、会话持久化与通道分发
  RootWorkspaceView.swift          主界面、侧边抽屉、顶部模型切换半屏与通知横幅
  ConnectAISheet.swift             「连接 AI」配置面板（网页登录 / API Key / 自定义网关）
  WebAdapterLoginSheet.swift       内置 WKWebView 登录视图与同源流式请求执行器
  SteerComposerBar.swift           底部输入栏、附件导入、深度思考开关与预设菜单
  MessageRowView.swift             消息流渲染、思考折叠块、代码块复制与工具卡片
  SecurityAndWorkspaceSheets.swift 项目目录管理、预设编辑与网络审计面板
  SettingsAndShareSheets.swift     个人资料、外观设置与对话长图分享

gateway/
  main.go / gateway.go / upstream.go / store.go  轻量 Go 语言 OpenAI 兼容转发与配额限流网关
```

> **范围说明**：`SandboxLift.swift`、`SandboxLiftProbe.swift`、`DeviceFilesystem.swift`、`DeviceFilesSheet.swift` 为早期遗留的未启用实验文件，因个人团队无 App Group 权限处于闲置状态，日常功能开发与代码审查**无需修改或涉及这几个文件**。

---

## 3. 核心实现要点（维护时请保持兼容）

1. **`URLSession.AsyncBytes.lines` 空行行为**：
   - Apple Foundation 的 `AsyncLineSequence` 会自动跳过空行（`\n\n`）。在 `WebAdapterClient.swift` 处理包含 `event: ready`、`event: update_session`、`event: title` 的 SSE 流时，每消费完紧随其后的一条 `data:` 行后必须立即将 `currentEvent` 重置为 `"message"`，否则后续不带 `event:` 行的正文帧会被误跳过。
2. **有状态增量帧与多格式 SSE 转换（`WebDeltaExtractor`）**：
   - `sse_deepseek`：首帧提供 `fragments` 快照，后续连续帧可能省略 `"p"` 字段仅发送 `{"v":"..."}`，解析器需记忆上一条路径并按 `fragment.type`（`THINK` / `RESPONSE`）区分推理过程与正文。
   - `sse_doubao`：同时兼容 `patch_op` 内容块与内嵌 JSON 字符串的 `message.content`；请求体模板中内嵌 JSON 字符串需使用双层转义占位符 `{{prompt_nested}}`，防止多行换行符 `\n` 破坏内层 JSON 语法。
   - `sse_qianwen`：兼容 `contents` 首帧快照与后续 RFC6902 `patch`（`op: "add" | "replace"`）增量追加。
     2026-11-20 实测千问前端 4.15.4：对话接口已迁到 `chat2.qianwen.com/api/v2/chat`（旧 `chat2-api.qianwen.com` 对该路径返回 404，且直发需页面内签名，会 403 `EX015 签名错误`）；正文改在 `data.messages[]` 里 `mime_type: "multi_load/iframe"` 的 `content` 累计快照中。短时间连发会触发阿里风控 `ret: ["FAIL_SYS_USER_VALIDATE","RGV587_ERROR::…"]`（跳 punish 滑块页），`errorEnvelope` 已转成人话，不要尝试绕过。
3. **`WebKitBrowserStreamPerformer` 生命周期（iOS 端）**：
   - 对于启用 `useBrowserContext` 的渠道，首次加载页面需等待 `document.readyState === 'complete'` 及输入组件就绪后再触发请求；React 18 受控 `<textarea>` 更新值时需同步触发节点上的 `onChange` 回调以保证状态同步。
4. **跨平台编译约束**：
   - `DeepSeekKit` 同时支持 macOS 14（用于快速运行 `swift test`）与 iOS 17+。任何 `UIKit` 或 iOS 专属 `WebKit` API 必须包裹在 `#if canImport(UIKit)` 或 `#if os(iOS)` 条件编译块中。
   - 中文字符串内避免混用未转义的英文双引号。
   - 未经用户明确要求，不要自动执行 `git commit` 或 `git push`。

---

## 4. 云端服务结构（`https://app.apifish.me`）

服务器：`<user>@<server-ip>`（Docker + Caddy 自动 HTTPS）

- `~/caddy/`：Caddy 容器配置，静态托管 `/specs.json`（供客户端同步最新渠道配置），其余路径反向代理至 `dsg-gateway:8787`。
- `~/gateway/`：Go 网关容器 `dsg-gateway`，配置文件位于 `~/gateway/config.json`，支持按 IP 每日免费额度限制、RPM 限流与管理端邀请链接生成。

---

## 5. 下一阶段全栈质量审查与优化清单

请在保持现有 46 项 Swift 单元测试与 Go 网关测试全部通过的前提下，对前后端与 UI/UX 进行全面体验审查与细节优化：

1. **客户端健壮性与异常处理**：
   - 为 `WebKitBrowserStreamPerformer` 增加流式超时看门狗（如超时无响应自动结束流并重置对应 `WKWebView`）以及 `webViewWebContentProcessDidTerminate` 进程回收后的自动恢复。
   - 检查 `syncRemoteWebSpecs()` 拉取的云端配置在本地的缓存持久化与字段合法性校验，保证离线冷启动也能使用最近一次同步的有效配置。
   - 检查 Swift 6 严格并发模型下的 `@MainActor`、Actor 隔离与任务取消（点击停止生成按钮时底层网络任务与 WebView 流的及时清理）。
2. **UI / UX 细节打磨**：
   - **模型列表搜索与自定义输入**：当网关返回较多模型（如 OpenRouter / 硅基流动）时，在顶部模型选择半屏中支持关键字过滤与手动输入自定义模型 ID。
   - **流式阅读体验**：优化长文本流式输出时的自动滚动逻辑（用户手动上滑阅读历史内容时不强制拉回底部，提供「回到底部」浮动按钮）。
   - **会话管理体验**：完善侧边抽屉中历史会话的重命名、空会话清理、长代码块横向滚动体验，以及深浅色模式在所有弹窗中的配色一致性。
   - **新用户引导**：优化未配置任何渠道时的首屏空状态提示，让新用户一步直达「连接 AI」。
3. **Go 网关（`gateway/`）与客户端联动**：
   - 完善客户端对网关 `402`（免费额度用尽）与 `429`（请求过快）状态码的友好提示文案。
   - 审查 `gateway/` 的并发读写锁、连接超时回收、日志脱敏与单元测试覆盖率。
