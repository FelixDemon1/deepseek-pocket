<h1 align="center">DeepSeek Go (iOS)</h1>

<p align="center">
  <b>纯净白蓝极简风格 · 兼容 iOS 17 / 18 / 26 / 27 全系 · 纯原生双核 AI Agent 工作台</b><br>
  <sub>#4D6BFE 经典白蓝美学 · 0 字节遥测 · 相册离线 Vision OCR · 免费/自建标准网关自动探测 · 直连电脑端 <code>dsh web</code></sub>
</p>

<p align="center">
  <img alt="Platform iOS 17+" src="https://img.shields.io/badge/iOS-17.0%20--%2027%2B-4D6BFE?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 6.0" src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Zero Telemetry" src="https://img.shields.io/badge/Telemetry-0%20Bytes-16A34A?style=flat-square">
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-64748B?style=flat-square">
</p>

---

## 小白零门槛安装矩阵（按难度从低到高）

1. **TestFlight 公开网页链接 / App Store（零门槛，普通用户首选）**  
   架构 100% 采用苹果公开 API（无 GPLv2 代码、无私有 API、无嵌套未签名动态库），已通过 Xcode `-validate-for-store` 静态上架检查。配置 Apple Developer 账号上传后开启 **TestFlight 公开邀请链接**，普通用户在微信/Safari 点开网页即可像装普通软件一样一键安装（注：正式提审 App Store 时建议显示名改为 `Go for DeepSeek` 等非官方从属名以符合苹果商标规范 5.2）。
2. **网页一键 OTA 直装 (`itms-services://`) 与 SideStore / AltStore 一键源**  
   仓库内置了网页安装页生成器 `scripts/generate-ota-manifest.sh`（产出 `dist/install.html` 与 `dist/manifest.plist`）以及软件源描述文件 `altstore-source.json`：
   - 已登记 UDID 的 Ad-Hoc 测试包或合规内部签名包：用户打开 `install.html` 点击蓝色按钮即可触发系统弹窗直接安装；
   - SideStore / AltStore 用户：点击网页中的 `sidestore://` / `altstore://` 按钮即可自动拉取 IPA 完成签名与后续自动更新。
3. **巨魔 TrollStore / 签名工具安装未签名 IPA**  
   直接从 Releases 获取 `DeepSeekGo-unsigned.ipa`（体积仅 ~1.6 MB，单层纯净 Bundle，不含复杂嵌套扩展，任何签名工具一次必过）。
4. **Mac 本地 Xcode 直装**  
   `open DeepSeekGo.xcodeproj` -> 选个人免费 Apple ID -> `Cmd + R`。

---

## 一键接入自建网关（零手打配置）

仓库内 `gateway/` 是一个 **OpenAI 兼容的 Go 网关**，用自己的上游 Key 免费开放给用户：

```bash
cd gateway && ./deploy.sh      # 生成 config.json → 填 sk- → 再跑一次
```

网关会提供一个落地页 `https://你的域名/`，用户点**「一键接入本网关」**即完成配置：

```
deepseekgo://setup?base=https://gw.example.com/v1&model=deepseek-chat&name=公益网关
```

App 收到深链后自动写入 Keychain、切换 provider、调用 `/v1/models` 探测模型，用户不需要知道什么是 endpoint。
网关首页会展示二维码，App 内「设置 → 扫码一键接入」用相机扫一下就完成，无需安装插件。

**不想自己申请 Key 的用户**：网关支持 BYOA（自带账号）模式 —— 用户关联**自己的**账号凭据，
凭据 AES-256-GCM 加密落盘、按身份隔离（A 的凭据绝不被 B 用到），不跨用户复用、无账号池。
公益模式默认三道闸保护运维者账户：每 IP 每日 token 额度、全站每日总额度、每 IP 每分钟限速。

## 核心特性

- **经典白蓝极简视觉**：纯白画布 (`#FFFFFF`) + 品牌皇家蓝 (`#4D6BFE`) + 冰蓝气泡 (`#EEF2FF`)，同时支持跟随系统与深邃暗色模式。
- **全系 iOS 兼容 (`iOS 17.0+`)**：原生覆盖 iOS 17、iOS 18、iOS 26 及后续 iOS 27 设备，体积仅 ~1.6 MB。
- **双核满血引擎**：本机原生 `AgentHarness`（R1 思考流、中途插话纠偏 `Steer`、挂载系统「文件 App」读写、Git 行级 Diff 审批、`JavaScriptCore` 本机验算、离线 `WKWebView` 交互卡片）+ 远程电脑端 `dsh web` 原生协议直连。
- **多渠道路由与离线读图**：内置官方 DeepSeek、OpenRouter 免费 R1 (`deepseek/deepseek-r1:free`) 及标准 OpenAI 兼容网关（支持 `http://127.0.0.1` / 局域网网关 `/v1/models` 自动探测）；支持 Apple Vision 相册图片纯离线 OCR。

---

## 构建与测试

```bash
# 运行核心安全与协议测试
(cd Packages/DeepSeekKit && swift test)

# 打包未签名 Release IPA (iOS 17.0+)
bash scripts/build-unsigned-ipa.sh

# 生成网页一键安装页 (dist/install.html + dist/manifest.plist)
bash scripts/generate-ota-manifest.sh https://your-domain.com/releases
```

---

## 许可证与商标说明

MIT License。本项目为独立社区开源客户端，与 DeepSeek 官方无隶属关系；应用内置图标为原创蓝白几何矢量图形，避免侵害第三方注册商标。
