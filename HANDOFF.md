# DeepSeek Pocket · 工程交接文档（HANDOFF）

> 更新：2026-11-20（第三轮）· 面向接手的 iOS / Go 工程师与编码助手。
> 先读 §0 和 §6，再按需查其余章节。代码是事实来源，本文与代码冲突时以代码为准。

---

## 0. 现状一页纸

iOS 原生（Swift 6 + SwiftUI）的手机端 agent，附带一个可选的 Go 网关 `gateway/`。
最新提交已推送到 `main`，CI 通过。

**能做什么**

| 能力 | 状态 |
| --- | --- |
| 三种接入：网页版登录（DeepSeek / 豆包 / 千问）、各厂商 API Key、自建网关 | 可用 |
| 多步工具循环（计划 → 执行 → 汇报），带审批与中途插话 | 可用；DeepSeek 网页版和 API Key 通道有工具，**豆包 / 千问只能聊天** |
| 工作区命令行 `run_shell`、文件读写、`run_javascript`、预览卡片 | 可用 |
| Python（`run_python`，numpy / pandas / matplotlib） | 可用，真机已验证 |
| 手机动作：提醒事项、日历、剪贴板、打开链接 | 代码与单测完成，**真机未验证** |
| 手机操控：读屏、点按、输入、开 App（`phone_look` / `phone_do`） | 需要从 Mac 启动驱动；模拟器和真机都跑通了完整任务（输入文字未单独验证） |
| 自建网关 `https://app.apifish.me` | 在线，但**上游密钥无效**，聊天请求全部失败（见 §6） |

**第一次接手建议先做**：跑一遍 §1 的测试 → 在模拟器里 `--demo` 看一轮完整流程 → 读 §6 的未完成项。

---

## 1. 构建 · 测试 · 安装

工作目录必须是仓库根目录。

```bash
# 单元测试
cd Packages/DeepSeekKit && swift test        # 期望：75 tests in 5 suites passed
cd ../../gateway && go test ./... && cd ..

# 真机包（把团队和 bundle id 换成自己的）
xcodebuild -project DeepSeekGo.xcodeproj -scheme DeepSeekGo \
  -destination 'generic/platform=iOS' -configuration Debug \
  DEVELOPMENT_TEAM=42A7TP5GH8 PRODUCT_BUNDLE_IDENTIFIER=io.deepseekgo.felix \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device 1AB8EF63-A612-5FE7-B105-10BC42A5AC4E \
  ~/Library/Developer/Xcode/DerivedData/DeepSeekGo-*/Build/Products/Debug-iphoneos/DeepSeekGo.app
xcrun devicectl device process launch --device 1AB8EF63-A612-5FE7-B105-10BC42A5AC4E \
  --terminate-existing io.deepseekgo.felix

# 模拟器包（bundle id 是 io.deepseekgo.ios）
xcodebuild -project DeepSeekGo.xcodeproj -scheme DeepSeekGo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -configuration Debug build

# 手机操控驱动（详见 PhoneRunner/README.md；命令运行期间有效）
xcodebuild test -project PhoneRunner/PhoneRunner.xcodeproj -scheme PhoneRunner \
  -destination 'id=<xcodebuild 里的设备 id>' \
  DEVELOPMENT_TEAM=42A7TP5GH8 PRODUCT_BUNDLE_IDENTIFIER=io.deepseekgo.felix.phonerunner \
  -allowProvisioningUpdates

# 云端
curl -sS https://app.apifish.me/healthz
```

- 设备锁屏时 `launch` 会报 `Locked`，解锁后重试。
- 真机上第一次启动 PhoneRunner 可能报 `Timed out while enabling automation mode`，再跑一次即可。
- `xcodebuild` 用的设备 id（`-showdestinations` 可查）和 `devicectl` 用的 UDID 不是同一个。

### 自检启动参数（都会把结果打到控制台）

| 参数 | 作用 |
| --- | --- |
| `--demo` | 不需要模型的演示：计划 → 命令 → Python 画图 → 写文件（要确认）→ 预览卡片 |
| `--verify-web` | 依次给 DeepSeek / 豆包 / 千问网页版发一句话 |
| `--verify-python` | 直接让工具层跑一段 numpy + matplotlib |
| `--verify-phone` | 通过 PhoneRunner 打开「设置」读屏并尝试点「通用」 |
| `--verify-agent ["任务"]` | 用 DeepSeek 网页版跑一个真实任务并打印每一步；等用户确认时会打印 `[AGENT-VERIFY-WAIT]` |

真机取控制台：`xcrun devicectl device process launch --console ... io.deepseekgo.felix --verify-python`。
模拟器取控制台：`xcrun simctl launch --console-pty <sim> io.deepseekgo.ios --verify-python`。

---

## 2. 目录地图

```text
Packages/DeepSeekKit/Sources/DeepSeekCore/     不依赖 UIKit / WebKit，可在 macOS 上单测
  Models.swift                数据模型
  AgentHarness.swift          多步工具循环、审批门（含「本轮都允许」）、中途插话、取消
  WorkspaceTools.swift        工具清单（schema）、审批规则、执行分发
  MiniShell.swift             run_shell：工作区内的迷你 Shell（Swift 实现，不是 Linux）
  ToolCallTextProtocol.swift  文本式工具调用：让只有文本框的网页接口也能调工具
  AgentRuntimes.swift         Python 运行时协议、运行时登记处、python3 / pip 命令行解析
  DeviceTools.swift           手机动作：提醒事项 / 日历 / 剪贴板 / 打开链接
  PhoneControl.swift          手机操控客户端（连 PhoneRunner）
  AgentPresentation.swift     工具 → 一行人话、计划解析、一轮执行的轨迹模型（AgentTurn）
  MarkdownBlocks.swift        Markdown 块级解析
  DeepSeekClient.swift / ResponsesClient.swift   OpenAI 兼容两种协议的流式客户端
  WebAdapterSpec.swift / WebAdapterClient.swift  网页版渠道规格、请求翻译、SSE 解析、DeepSeek PoW
  PrivacyFirewall.swift       出站白名单与联网审计
  CredentialVault.swift / SetupLink.swift / KeyProviderCatalogue.swift / PurgeProfile.swift

Packages/DeepSeekKit/Sources/DeepSeekUI/
  AppViewModel.swift               全局状态、会话持久化、回合生命周期
  RootWorkspaceView.swift          主界面：顶栏、首页、消息列表、抽屉、模型选择
  AgentTurnView.swift              一轮执行的轨迹：计划卡、步骤行、终端块、交付卡、实时状态条
  MessageRowView.swift             用户气泡、助手正文与操作栏、审批卡、Diff
  MarkdownView.swift               Markdown 渲染
  PyodideRuntime.swift             Python 运行时（隐藏 WKWebView + Pyodide）
  WebAdapterLoginSheet.swift       网页登录 + 隐藏 WebView 流式执行器（豆包 / 千问）
  SteerComposerBar.swift / ConnectAISheet.swift / SettingsAndShareSheets.swift / SecurityAndWorkspaceSheets.swift

PhoneRunner/     独立 Xcode 工程：XCUITest 手机操控驱动（主工程和 CI 不依赖它）
gateway/         Go 网关
App/             App 入口、Info.plist、深链与自检参数
```

`SandboxLift*.swift`、`DeviceFilesystem.swift`、`DeviceFilesSheet.swift` 是早期遗留的未启用实验文件，不用碰。

---

## 3. 必须保持的实现要点

### 3.1 网页版通道（改之前先跑 `--verify-web`）

1. `URLSession.AsyncBytes.lines` 会吞掉空行。`WebAdapterClient` 每消费一条 `data:` 行就把 `currentEvent` 重置为 `"message"`，否则后面不带 `event:` 的正文帧会被跳过。
2. `WebDeltaExtractor` 是有状态的：
   - `sse_deepseek`：首帧 `fragments` 快照，后续帧可能省略 `p` 只给 `{"v":"…"}`，按 fragment 类型区分思考与正文。
   - `sse_doubao`：兼容 `patch_op` 与内嵌 JSON 字符串；请求体里内嵌 JSON 用 `{{prompt_nested}}`（双层转义）。
   - `sse_qianwen`：千问前端 4.15.4 起接口是 `chat2.qianwen.com/api/v2/chat`，正文在 `data.messages[]` 里 `mime_type: "multi_load/iframe"` 的 `content` 累计快照中；同时兼容旧的 `contents` + JSON Patch。
3. DeepSeek 网页版需要先建会话，再解 `DeepSeekHashV1` 工作量证明（23 轮 Keccak，跳过第一个轮常量）。有逐位对拍的单测，别改算法。
4. 豆包 / 千问靠隐藏 WKWebView 驱动官网页面发送（`WebKitBrowserStreamPerformer`）：等页面就绪后留 1.6 秒让签名脚本初始化；用 React 的 `onChange` 写入受控输入框；同一渠道的请求串行；首包 45 秒 / 空闲 90 秒看门狗；网页进程被回收后自动重建。
5. 千问短时间连发会触发阿里风控（`FAIL_SYS_USER_VALIDATE` / `RGV587`，跳滑块页）。已翻译成人话，不要尝试绕过。

### 3.2 工具与审批

1. **工具从哪来**：`WorkspaceToolset.toolSchemas` 是唯一清单。API Key 通道走原生 function calling；DeepSeek 网页版走 `ToolCallTextProtocol`（模型输出 ` ```tool ` 代码块，本机截留解析）。`WebAdapterTransport.supportsTextTools` 决定哪些网页渠道开放工具——凡是 `useBrowserContext` 的都不开放，因为多步循环会连开新对话并触发风控。
2. **审批规则**（`requiresApproval`）：
   - `update_plan` 永不询问。
   - 手机动作（`DeviceTools`）和手机操控（`PhoneControl`）在任何策略下都询问；手机操控可以「本轮都允许」。
   - 标准防护下：写文件、改文件、会改动工作区的 `run_shell`、`run_python`、联网抓取要询问。
   - `MiniShell.isMutating` 解析不了的命令一律按「会改动」处理。
3. **停止**：`AgentHarness` 在流结束后显式检查取消；等待审批的 continuation 可取消。`AppViewModel` 用 `turnGeneration` 丢弃旧回合的迟到事件。相关单测在 `LifecycleHardeningTests`。
4. **Python**（`PyodideRuntime`）：页面走自定义协议 `pyrt://`，所有资源由 `PyodideSchemeHandler` 提供——先读 `Caches/pyodide-0.29.5/`，没有再经 `PrivacyFirewall` 从 jsDelivr 下载并缓存。页面 CSP 只允许 `pyrt:`，Python 代码不能自己联网。每次运行前把工作区同步进内存文件系统，运行后把新增 / 改动的文件写回。超时 120 秒或取消时直接销毁 WebView。
5. **手机操控**：每次调用的流程是「切到目标 App → 执行 → 读屏 → 切回本 App」，所以不需要后台保活，确认卡也始终能在本 App 里点到。`phone_*` 工具只在驱动在线时才出现在工具清单里（`AgentRuntimeHooks.phoneAvailable`，每轮开始前探测）。

### 3.3 工程约束

- `DeepSeekKit` 同时给 macOS 编译（跑 `swift test`）。UIKit / iOS 专属 API 必须包在 `#if canImport(UIKit)` 或 `#if os(iOS)` 里。
- 测试用 Swift Testing（`@Suite` / `@Test` / `#expect`），写 XCTest 类不会被发现。
- 中文字符串里不要直接写英文双引号。往 Swift 源码里嵌 JSON 时，带中文的内容用 `JSONSerialization` 生成，不要用 `#"…"#` 手写（会编译失败）。
- 未经用户明确要求不要 `git commit` / `git push`。
- **仓库是公开的**：不要把服务器地址、登录名、密钥写进任何会提交的文件。
- 参考过的 dsh-Go 和 Poki 都是 AGPL-3.0，本仓库是 MIT：只借鉴交互思路，不要复制它们的代码。

---

## 4. 云端（`https://app.apifish.me`）

服务器：`<user>@<server-ip>`（Docker + Caddy 自动 HTTPS；登录信息在本地，不入库）。

- `~/caddy/`：Caddy 配置；`site/specs.json` 是客户端热更新的渠道规格（按 id 覆盖内置预设，客户端会校验并缓存）。
- `~/gateway/`：Go 网关容器 `dsg-gateway`，配置在 `~/gateway/config.json`。
- 部署方式：把 `gateway/*.go` 同步到 `~/gateway/`，在那里 `docker compose up -d --build`。服务器上没有 Go，测试用 `docker run --rm -v ~/gateway:/src -w /src golang:1.24-alpine go test ./...`。
- 网关与本仓库 `gateway/` 当前一致（上一轮已部署）。

---

## 5. 验证记录（2026-11-20）

| 项目 | 怎么验的 | 结果 |
| --- | --- | --- |
| Swift 单测 | `swift test` | 75 项通过 |
| Go 网关 | `go test ./...` | 通过 |
| CI | GitHub Actions | 通过（测试 + 未签名 IPA） |
| 三个网页渠道 | 真机 `--verify-web` | 上一轮全部「连接成功」；本轮没有重跑 |
| DeepSeek 网页版多步任务 | 真机 `--verify-agent` | 两个任务跑通（命令行 → 读文件 → 写文件 → 汇报） |
| Python | 真机 `--verify-python` | 通过，画图 2.6 秒 |
| 手机操控驱动 | 模拟器：打开设置 → 点进通用 → 回到本 App | 通过 |
| 手机操控驱动 | 真机：启动驱动、读「设置」屏幕、滑动 | 通过 |
| 模型驱动的手机操控 | 真机 `--verify-agent`，DeepSeek 网页版 | 通过：打开设置 → 点「通用」→ 点「关于本机」→ 读出 iOS 26.3 / iPhone 17 Pro Max，共 3 步；用户点了一次「本轮都允许」后不再询问 |
| 界面 | 模拟器截图（浅色 + 深色）：首页、抽屉、演示全流程、设置 | 看过；真机上没有逐屏看 |
| 手机动作（提醒 / 日历 / 剪贴板 / 打开链接） | 仅单测（参数校验、审批规则） | **真机未验证**，系统授权弹窗也没见过 |
| API Key 通道下的新工具 | – | **未验证**（没有可用的 Key） |

---

## 6. 未完成与已知问题（按建议的处理顺序）

1. **网关上游密钥无效**。`~/gateway/config.json` 里的 DeepSeek key 被上游以 401 拒绝，经网关的聊天请求全部失败。需要人填入真实 key 后在 `~/gateway` 执行 `docker compose up -d`。
2. **手机操控还没验证的动作**：输入文字（`type`）、长按、返回手势、跨 App 的任务。读屏、点按、滑动和「本轮都允许」已在真机上验证。
3. **真机验证手机动作**：让它建一条提醒和一个日程，确认授权弹窗、写入结果和失败提示。
4. **用户手机上的审批设置是「沙盒全自动」**（写文件、跑脚本不询问）。这是用户确认过要保留的，不要擅自改回。
5. **手机操控的边界**：
   - 需要 Mac 启动驱动，脱离电脑独立运行没有做。
   - 驱动的本机接口没有鉴权（运行期间本机其他 App 也能调用）。
   - 只读得到无障碍树，没有截图 / OCR，纯图片界面读不到。
   - 只跟踪由它自己打开的 App。
6. **Python 的边界**：不是 Linux；只有 Pyodide 自带的包（没有 openpyxl，装不了 PyPI 上的包）；不能联网；matplotlib 没有中文字体；运行期间的输出要等结束后才显示。
7. **豆包 / 千问没有工具**。要开放需要先解决「每一步都新开官网对话」的问题（复用同一个官网会话）。
8. **界面还没做的**：
   - 「连接 AI」和设置页仍是系统默认表单样式，和新首页、抽屉的风格不统一。
   - 流式输出没有打字光标；代码块没有语法高亮。
   - Markdown 每来一个分片就整段重新解析，长回答可能有性能问题，没有测量过。
   - iPad / 横屏布局没有适配。
9. **演示（`--demo`）依赖 Python 运行时**，首次需要联网下载约 12MB；失败时演示会如实说明图没画出来。
10. 低优先级：`/healthz` 暴露用户数和上游地址；发送前的凭据检查每次重绘都读 Keychain；重新登录网页渠道后旧 cookie 可能残留。

---

## 7. 本地辅助脚本（不在仓库里）

上一轮在 `/Users/qinzihan/AI_huancun/agent-refs/` 留下了几个脚本和参考资料，接手时可以直接用：

- `runner.sh`：在模拟器上启动 PhoneRunner 并等它上线。
- `ui.py`：通过 PhoneRunner 驱动模拟器里的 App（`look` / `tap <文字>` / `do <动作 JSON>` / `shot <名字>` / `sheet` 拼图）。用它可以真正点自己的界面做回归。
- `simrun.sh` / `devrun.sh`：带自检参数启动模拟器 / 真机上的 App 并等待标记输出。
- `shots/`：各轮截图；`dsh-Go/`、`poki/`：两个参考项目的只读克隆（AGPL，仅供看交互）。

这个目录约 1GB，不需要时可以整个删除。
