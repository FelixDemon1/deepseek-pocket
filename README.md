<h1 align="center">Tide (潮汐)</h1>

<p align="center">
  <b>纯净白蓝极简风格 · 原创像素伙伴「小潮」 · 兼容 iOS 17–27 全系 · 纯原生双核 AI Agent 工作台</b><br>
  <sub>0 字节遥测 · 官方外部文件夹挂载授权 · 相册离线 Vision OCR · 扫码一键接入自建网关 · 直连电脑端 <code>dsh web</code></sub>
</p>

<p align="center">
  <img alt="Platform iOS 17+" src="https://img.shields.io/badge/iOS-17.0%20--%2027%2B-4D6BFE?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 6.0" src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Zero Telemetry" src="https://img.shields.io/badge/Telemetry-0%20Bytes-16A34A?style=flat-square">
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-64748B?style=flat-square">
</p>

---

## 核心亮点

- **独立原创品牌与像素伙伴「小潮」**：经典白蓝极简界面 (`#FFFFFF` + `#4D6BFE`)，内置 100% 原创矢量像素桌面伙伴「小潮」（随待机、深度思考、敲代码跑工具、等待审批、任务完成实时切换 5 种像素动作，点按有互动反馈，亦可在设置关闭）。
- **合规全目录文件授权（免越狱、零漏洞依赖）**：除内置沙盒工作区外，支持苹果官方 `Security-Scoped Bookmark` 外部目录挂载——用户可在「本机工作区」点击授权任意 iOS「文件 App」文件夹（iCloud Drive、Working Copy 本地 Git 仓库、外接 U 盘、局域网 SMB 共享）供 Agent 直接读写并输出行级 Git Diff。
- **扫码一键接入自建网关 (`gateway/`)**：配套 Go 语言标准 OpenAI 兼容网关，支持公益免 Key 限额模式与隔离式自带凭据模式；手机端在「设置 → 扫码一键接入」对准网关二维码或点击 `tide://setup?...` 链接即可完成配置并自动探测 `/v1/models`。
- **双核满血引擎（安装包仅 ~1.4 MB）**：本机原生 `AgentHarness`（R1 思考流、中途插话纠偏 `Steer`、`JavaScriptCore` 本机验算、离线隔离 `WKWebView` 交互卡片、Apple Vision 相册离线 OCR）+ 远程电脑端 `dsh web` 协议直连。

---

## 小白零门槛安装方式

1. **TestFlight 公开链接 / App Store**：100% 苹果公开 API 实现，无 GPLv2 与商标冲突，支持直接提审。
2. **网页一键 OTA 直装 (`itms-services://`) 与 SideStore / AltStore 源**：内置 `scripts/generate-ota-manifest.sh` 与 `altstore-source.json`。
3. **巨魔 TrollStore / 自签工具**：在 [Releases](https://github.com/FelixDemon1/tide-ios/releases/latest) 下载单层纯净未签名 IPA。
4. **Mac 本地 Xcode 直装**：`open DeepSeekGo.xcodeproj` -> 选择个人 Apple ID Team -> `Cmd + R`。

---

## 构建与测试

```bash
(cd Packages/DeepSeekKit && swift test)
(cd gateway && go test ./... && go vet ./...)
bash scripts/build-unsigned-ipa.sh
```

---

## 许可证

MIT License。全部代码、品牌名称 **Tide** 与原创像素伙伴图像均以 MIT 协议开源，不依赖任何受限第三方美术资产。
