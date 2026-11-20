# PhoneRunner · 手机操控驱动

让 DeepSeek Pocket 里的 agent 能看屏幕、点按、输入、打开别的 App。

它是一个不会结束的 XCUITest，在手机本机 `127.0.0.1:28467` 上开一个小 HTTP 服务。
XCUITest 只有由 Xcode / xcodebuild 启动的测试进程才能用，所以**需要从 Mac 启动一次**，
并且只在这条命令运行期间有效（按 Ctrl-C 即停止）。

```bash
# 真机（把 UDID 和团队换成自己的）
xcodebuild test -project PhoneRunner/PhoneRunner.xcodeproj -scheme PhoneRunner \
  -destination 'id=<设备 UDID>' \
  DEVELOPMENT_TEAM=<团队 ID> PRODUCT_BUNDLE_IDENTIFIER=<你的前缀>.phonerunner \
  -allowProvisioningUpdates

# 模拟器
xcodebuild test -project PhoneRunner/PhoneRunner.xcodeproj -scheme PhoneRunner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

真机上需要先在「设置 › 开发者」里打开 **Enable UI Automation**。

## 接口

| 路径 | 请求体 | 作用 |
| --- | --- | --- |
| `GET /status` | – | 是否在线 |
| `POST /look` | `{"app": "com.apple.Preferences", "returnTo": "<调用方 bundle id>"}` | 打开/切到某个 App 并返回屏幕元素；不给 `app` 则看当前目标 App |
| `POST /do` | `{"actions": [...], "returnTo": "..."}` | 依次执行动作，最后返回新的屏幕元素 |

动作：`launch`(app) · `tap`(element 或 x,y) · `long_press` · `type`(text, enter) · `swipe`(direction) · `back` · `home` · `wait`(seconds)。
某个动作失败后，后面的动作不再执行。

## 已知限制

- 服务没有鉴权：运行期间，手机上任何能访问本机回环地址的 App 都能调用它（与 WebDriverAgent 相同）。不用时停掉。
- 只跟踪由它自己打开的 App；用户手动切到别的 App 后，需要再用 `launch` 指明目标。
- 脱离 Mac 独立启动（Poki 的回环 VPN 方案）没有实现。
