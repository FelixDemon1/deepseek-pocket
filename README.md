# DeepSeek Pocket

iOS 原生极简 AI Agent 工作区（Swift 6 · iOS 17–27+ · 0 字节遥测）。

## 架构

- **`Packages/DeepSeekKit`**
  - `DeepSeekCore`：R1/V3 流式 SSE、中途插话队列 (`Steer`)、本机/外部挂载目录读写与 Git Diff、JavaScriptCore 沙盒、Apple Vision 离线识图、出站白名单防火墙、`dsh web` 直连协议、`deepseekpocket://setup` 扫码配网。
  - `DeepSeekUI`：极简单层工作台、像素蓝鲸状态伙伴、零网络隔离 `WKWebView` 视图预览。
- **`gateway/`**：可选自建 Go 网关（支持免 Key 限额模式与二维码一键配网）。

## 构建与安装

```bash
# 运行全部测试（Swift + Go）
(cd Packages/DeepSeekKit && swift test)
(cd gateway && go test ./... && go vet ./...)

# 构建未签名 IPA (dist/DeepSeekGo-unsigned.ipa)
bash scripts/build-unsigned-ipa.sh

# Xcode 真机安装
open DeepSeekGo.xcodeproj
```

直接下载未签名包：[Releases](https://github.com/FelixDemon1/deepseek-pocket/releases/latest)（支持 TrollStore、SideStore、AltStore 及网页 OTA）。

## 许可

MIT License。独立社区开源项目，与 DeepSeek 官方无隶属关系。
