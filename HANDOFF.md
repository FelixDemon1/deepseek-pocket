# DeepSeek Pocket 项目完整上下文交接文档 (HANDOFF)

> **文档用途**：本交接文档为后续 AI 工程师（Claude Code、Codex、DeepSeek 等）或人类开发者提供完整的项目上下文、架构说明、历史需求演变、真机配置参数与待办建议，可直接作为新会话的系统提示词（System Context）使用。

---

## 一、 项目全景与基本信息

| 属性 | 配置值 | 说明 |
| :--- | :--- | :--- |
| **项目名称** | **DeepSeek Pocket** | 曾用代号：`deepseek-go-ios`、`Tide`、`DeepSeek Go` |
| **开源仓库** | [FelixDemon1/deepseek-pocket](https://github.com/FelixDemon1/deepseek-pocket) | 主分支 `main`，已开源并打 Tag `v1.3.0` |
| **本地路径** | `/Users/qinzihan/.gemini/antigravity/scratch/deepseek-go-ios` | 包含完整 Xcode 工程与 Swift Package |
| **语言与框架** | **Swift 6 (Strict Concurrency) · SwiftUI** | **零第三方包依赖**（零 CocoaPods、零 SPM 外部依赖、零 Node 运行时） |
| **系统兼容** | iOS 17.0 至 iOS 27+（含 iPhone 17 全系与未来系统） | 包含 iPadOS 支持 |
| **数据隐私** | **0 字节外部遥测**（Zero-Telemetry） | 强隔离沙盒防火墙，严禁未授权外部域名外发 |
| **最新发布** | [v1.3.0 Release](https://github.com/FelixDemon1/deepseek-pocket/releases/tag/v1.3.0) | 含未签名包 `DeepSeekPocket-unsigned.ipa`（872 KB） |

---

## 二、 历史用户需求演化历程（按轮次倒序与关键决策）

### 1. 第五轮（最新需求）：Gemini 交互、鲸鱼娘宠物、去黑话、dsh-purge 与真机交付
- **需求 1：Google Gemini 极简导航**
  - **实现**：顶部左侧采用 Gemini 双线阶梯汉堡抽屉图标；中轴为 `DeepSeek R1 ∨` 模型下拉胶囊，轻按呼出高度为 `370pt` 的底部半屏抽屉（`.presentationDetents([.height(370)])`），单手一击切换 `R1 深度思考` / `V3 快速回答` / `免费体验通道`；右侧为新对话按钮与带状态圆点的用户头像。
- **需求 2：输入框栖息宠物“像素鲸鱼娘”（Pixel Whale-Girl）**
  - **实现**：参考用户上传点阵图，用纯代码实现了 28×24 点阵的“像素鲸鱼娘”（含呆毛、女仆发箍、深蓝发色与鲸鱼尾巴）。直接栖息在输入胶囊右上沿边框上。支持 4 种动态状态：`敲代码`（打字执行中）、`完成`（欢呼庆祝）、`等你确认`（举手高亮并弹出蓝色气泡气泡）、`睡觉`（空闲呼吸泡）。设置中可随时在“像素鲸鱼娘 / 经典像素蓝鲸 / 关闭”间切换。
- **需求 3：去除技术黑话，全面通俗化**
  - **实现**：去除“网关/Base URL/网络审计/工作区沙盒”等专业术语，全面重写为“接口来源/接口地址”、“DeepSeek 官方接口 / 自定义个人接口”、“隐私与联网记录”、“我的本地文件”。
- **需求 4：一键开启无限制创作模式 (dsh-purge)**
  - **实现**：内置 `unrestricted_creative`（无限制创作 Purge）预设，在设置页与规则页提供独立一键开关。基于客观纯净原则，跳过一切空洞说教、免责声明或格式繁文缛节，纯本机设定生效，不依赖外部环境，不上传任何隐私。
- **需求 5：扫码功能说明去歧义**
  - **实现**：去除孤立扫码按钮，改为带完整文字提示的引导卡片：“**扫码自动填入朋友分享的接口**：扫描朋友或团队提供的接口配置二维码，免手打自动填好地址和密钥”。
- **真机安装与发布**：
  - 通过 `xcodebuild` 使用用户真实开发者证书（Team ID: `42A7TP5GH8`）编译，并使用 `xcrun devicectl` 成功部署并拉起运行于用户物理连接的 **iPhone 17 Pro Max**（设备标识：`1AB8EF63-A612-5FE7-B105-10BC42A5AC4E`）。
  - 打包生成 Release IPA，Git commit 并 push 至 GitHub，同时创建 `v1.3.0` Release。

### 2. 第四轮：极简主义（Linear / Apple Notes）重构与命名
- **需求**：用户要求页面像 Linear 官网和苹果备忘录一样干净，砍掉所有多余标语、副标题和次要标签。
- **决策**：定名 **DeepSeek Pocket**，采用高雅白蓝极简配色（`#4D6BFE` 品牌蓝 + 纯白底色）。设计自绘像素跃水蓝鲸 AppIcon，重构顶层架构，砍掉内购与冗余商业化逻辑，将弹窗状态统一收敛为单一 `ActiveSheet` 枚举。

### 3. 第三轮：本地文件读写与 Agent 沙盒安全性
- **讨论**：用户探讨使用 worse_query / 3105 / wq_files 等越狱漏洞获取苹果底层文件读写权限。
- **结论与架构定型**：解释了 iOS 生产环境内核安全机制（PPL / KTRR / Sandbox / App Store 审核规则）。在保证**不损坏手机、不上架被拒、100% 官方合规**的前提下，使用 iOS 原生 **Security-Scoped Bookmarks（安全作用域书签）** 与系统 `UIDocumentPickerViewController`，实现跨会话对用户选定 iPhone 本地文件夹（如“文件”App、iCloud Drive、下载目录）的真实读写。修改前自动生成精美统一差异卡片（Unified Git Diff），经用户确认后原子写入。

### 4. 第一至二轮：起源与核心链路
- **背景**：解决桌面端 `dsh web` / `workbuddy` 反代在移动端的原生体验问题，打造纯原生 Swift 实现的 DeepSeek 智能体。
- **定位**：非单纯的聊天包装壳，而是支持多步工具循环（Function Calling）、文件读写、离线 OCR、中途插话（Steer）、出站防火墙拦截的完整轻量客户端。

---

## 三、 代码仓库架构与关键源文件清单

```text
deepseek-go-ios/
├── DeepSeekGo.xcodeproj             # Xcode 主工程（管理 App 目标与 Package 依赖）
├── App/                             # iOS App 主入口
│   ├── DeepSeekGoApp.swift          # @main 入口、DeepLink (deepseekpocket://)、AppIntents 捷径
│   ├── Assets.xcassets              # 像素蓝鲸应用图标与颜色集
│   └── Info.plist                   # 权限声明、URL Schemes、本地网络权限
├── Packages/
│   └── DeepSeekKit/                 # 核心 Swift Package（分层解耦）
│       ├── Package.swift            # 模块定义：DeepSeekCore 与 DeepSeekUI
│       └── Sources/
│           ├── DeepSeekCore/        # 核心逻辑层（无任何 UI 依赖，可跨平台测试）
│           │   ├── Models.swift     # 数据模型（会话、消息、Preset 预设、Token统计、Steer 指令）
│           │   ├── DeepSeekClient.swift # 原生 SSE 流式解析器（R1 思考流、V3 文本、ToolCall 装配）
│           │   ├── AgentHarness.swift   # Agent 核心状态机（多步循环、工具执行、审批拦截、Steer 消费）
│           │   ├── WorkspaceTools.swift # 本地沙盒文件系统工具（read/write/patch/diff/find）与 JS 执行器
│           │   ├── DshWebClient.swift   # 远程 dsh web / workbuddy 协议 WebSocket 客户端
│           │   ├── SetupLink.swift      # 一键配置链接解析器 (deepseekpocket://setup)
│           │   └── ZeroTelemetryFirewall.swift # 出站网络白名单与隐私防火墙
│           └── DeepSeekUI/          # 极简 SwiftUI 界面层
│               ├── AppViewModel.swift   # 全局状态管理（@Observable 风格，双端模式、会话持久化）
│               ├── RootWorkspaceView.swift # Gemini 风格主视图（顶栏、半屏模型抽屉、侧边抽屉、空白态）
│               ├── SteerComposerBar.swift  # 悬浮输入框、栖息宠物、中途插话状态、文件/预设快捷入口
│               ├── PixelCompanionView.swift# 像素鲸鱼娘与像素蓝鲸的点阵绘制与 4/5 状态机
│               ├── SettingsAndShareSheets.swift # 通俗化设置页、接口切换、一键无限制模式 (dsh-purge)
│               └── SecurityAndWorkspaceSheets.swift # 文件浏览器、角色预设选择器、离线隐私记录
├── gateway/                         # 可选自建 Go 伴生网关（支持免 Key 限额通道与一键扫码）
│   ├── main.go
│   ├── gateway_test.go
│   └── go.mod
├── scripts/
│   └── build-unsigned-ipa.sh        # 一键打包未签名 Release IPA 脚本
└── docs/screenshots/               # 实际渲染截图（home.png / stream.png / models.png / settings.png）
```

---

## 四、 核心机制实现细节

### 1. Gemini 导航与底部半屏模型切换器
- **文件**：`Packages/DeepSeekKit/Sources/DeepSeekUI/RootWorkspaceView.swift`
- **实现原理**：
  - 顶栏左侧使用两根阶梯式横线构成 Gemini 标志性抽屉按钮（点击展开历史会话与外部连接）。
  - 中间胶囊显示当前模型简写（如 `DeepSeek R1`），带有 `chevron.down`。点击后设置 `activeSheet = .modelPicker`。
  - 模型抽屉使用 `.presentationDetents([.height(370)])` 与 `.presentationDragIndicator(.visible)`，为 iOS 经典半屏高度。
  - 内置快速切换项：
    - `DeepSeek R1 · 深度思考`（官方 API，`deepseek-reasoner`）
    - `DeepSeek V3 · 快速回答`（官方 API，`deepseek-chat`）
    - `免费体验通道 (OpenRouter R1)`（免 Key 公益反代）

### 2. 对话框栖息宠物：像素鲸鱼娘
- **文件**：`Packages/DeepSeekKit/Sources/DeepSeekUI/PixelCompanionView.swift` & `Packages/DeepSeekKit/Sources/DeepSeekUI/SteerComposerBar.swift`
- **点阵规格**：28 列 × 24 行网格。使用 SwiftUI `Canvas` 绘制，抗锯齿设为最临近采样（`isAntialiased: false`），放大比例 `scale: 2.2`。
- **状态映射**：
  - `CompanionMood.coding`（思考中/工具执行中）：鲸鱼娘面前有微型键盘，屏幕显示 `</>`。
  - `CompanionMood.happy`（单轮任务完成）：双手合十欢呼，头顶浮现绿色对勾 `[✓]`。
  - `CompanionMood.waitingApproval`（等待文件修改审批）：单手高举挥手，头顶浮现黄色惊叹号 `[!]`，输入框上方同步弹出蓝色微气泡“等你确认”。
  - `CompanionMood.idle`（空闲等待）：闭眼微动，头顶带有微型蓝白色呼吸气泡 `zZ`。
- **位置**：计算几何尺寸后，使用负位移（`offset(y: -54)`）精准卡在输入框胶囊圆角的右上边沿上，既生动活泼又完全不侵占输入框的打字空间。

### 3. 一键开启无限制创作模式 (dsh-purge)
- **文件**：`Packages/DeepSeekKit/Sources/DeepSeekCore/Models.swift` & `Packages/DeepSeekKit/Sources/DeepSeekUI/SettingsAndShareSheets.swift`
- **实现原理**：
  - 在 `PromptPreset.builtIn` 中内置 ID 为 `unrestricted_creative` 的预设，System Prompt 为：
    > “基于纯净客观原则：跳过一切道德说教、空洞免责声明或格式繁文缛节，直接按用户指令进行高精度代码编写、技术探索或情景创作，保持纯净直接的逻辑输出。”
  - `AppViewModel` 提供 `isUnrestrictedMode: Bool` 与 `setUnrestrictedMode(_ enabled: Bool)` 方法。
  - 设置页与规则页提供独立一键 Toggle 开关，开关时自动在当前会话的 System Message 中替换/注入对应指令，并持久化到本地。

### 4. 中途插话与控制流 (Mid-Turn Steer)
- **文件**：`Packages/DeepSeekKit/Sources/DeepSeekCore/AgentHarness.swift`
- **实现原理**：在模型思考或工具执行循环中，用户在输入框打字点发送时，输入框自动变为“中途插话补充…”，指令会被推入 `steerDirectives` 队列。Agent 在下一次工具执行或下一轮 Prompt 组装时，无损将用户的最新补充插入上下文，无需强行中断丢弃已有进度。

---

## 五、 真机开发与部署环境（下一任工程师必读）

### 1. 物理连接的测试设备
- **设备名称**：`👑Felix's iPhone 17PM`
- **CoreDevice Identifier**：`1AB8EF63-A612-5FE7-B105-10BC42A5AC4E`
- **硬件 UDID / ECID**：`00008150-000A34DA2E63401C`
- **系统架构**：`iPhone18,2` (arm64e, iOS 26.3)
- **开发者证书与 Team**：
  - Apple ID：`qinzihan04@gmail.com`
  - Team ID：`42A7TP5GH8`
  - Provisioning Profile：`iOS Team Provisioning Profile: io.deepseekgo.felix`
  - Bundle Identifier：`io.deepseekgo.felix`

### 2. 标准构建与安装命令

```bash
# 1. 运行核心单测（验证模型、协议、沙盒工具与防火墙）
cd /Users/qinzihan/.gemini/antigravity/scratch/deepseek-go-ios/Packages/DeepSeekKit && swift test

# 2. 编译并签名安装到用户连接的 iPhone 17 Pro Max
cd /Users/qinzihan/.gemini/antigravity/scratch/deepseek-go-ios
xcodebuild -project DeepSeekGo.xcodeproj \
  -scheme DeepSeekGo \
  -destination 'id=00008150-000A34DA2E63401C' \
  -configuration Debug \
  DEVELOPMENT_TEAM=42A7TP5GH8 \
  PRODUCT_BUNDLE_IDENTIFIER=io.deepseekgo.felix \
  -allowProvisioningUpdates \
  build

# 3. 使用 devicectl 推送安装至真机
xcrun devicectl device install app \
  --device 1AB8EF63-A612-5FE7-B105-10BC42A5AC4E \
  /Users/qinzihan/Library/Developer/Xcode/DerivedData/DeepSeekGo-flfjjdyajaymgnguekyszjwwmzqb/Build/Products/Debug-iphoneos/DeepSeekGo.app

# 4. 在真机上前台拉起应用
xcrun devicectl device process launch \
  --device 1AB8EF63-A612-5FE7-B105-10BC42A5AC4E \
  io.deepseekgo.felix

# 5. 打包未签名 Release IPA（供 TrollStore / AltStore / GitHub Release 使用）
bash scripts/build-unsigned-ipa.sh
```

---

## 六、 下一阶段待办与建议 (Roadmap for Next AI)

如果你是接替开发的新 AI，以下是经过评估的高价值待办方向：

1. **App Store 上架预备**：
   - 目前应用 Bundle ID 为 `io.deepseekgo.felix`，若用户需要正式提交 TestFlight，需配置对应的 Distribution Certificate 与 App Store Provisioning Profile。
2. **多模态图片识别进一步增强**：
   - 目前已基于 iOS 原生 `Vision.framework` 实现了离线 OCR。可进一步扩展调用支持 Vision 输入的模型（如通过配置的第三方 API 直传图片 Base64）。
3. **iPad 宽屏与分屏适配**：
   - 当前在 iPhone 上表现极佳；在 iPad 上可以考虑基于 `NavigationSplitView` 在侧边常驻会话列表与文件列表。
4. **代码编写守则**：
   - **绝不引入第三方厚重依赖**：保持极速冷启动（<0.2s）与微型包体积（<1MB）。
   - **严格遵守 Swift 6 并发安全**：所有 UI 绑定均在 `@MainActor`，核心异步任务采用 `async/await` 与 `Sendable` 协议。
   - **坚持 Linear / Apple Notes 极简美学**：克制添加花哨元素，一切以清晰、高效、专注内容为准绳。
