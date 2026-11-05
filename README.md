# CIA Bridge

CIA Bridge 是一个受 LocalSend 操作逻辑启发、跨 Windows 与 Android 的 FBI 局域网投送器。选择已经下载到手机或电脑的 `.cia` 文件后，它会自动查找附近的 Nintendo 3DS，在本机启动临时 HTTP 服务，并生成二维码或把链接主动推送给 FBI。文件不会上传到公网。

## 特点

- Windows 与 Android 使用同一套 LocalSend 风格 Flutter 界面，并针对桌面与手机宽度自动重排；顶栏可自由选择跟随系统、浅色或深色主题。
- 发送流程采用渐进式两阶段流水线：第一屏只负责发现并选择 3DS，选择后平滑进入“选择文件并发送”；后续控件不会提前挤在主界面中。
- 设备卡片只负责选择；选好文件后才在当前内容中显示醒目的渐变发送按钮和二维码备用操作，不使用破坏整体性的固定底栏。
- 自动预热并读取局域网邻居表，能读取 MAC 时使用 Nintendo OUI 精确识别 3DS；现代 Android 隐藏邻居 MAC 时会安全列出同网段在线候选，点选与 FBI 屏幕 IP 一致的设备即可，无需手输地址和端口。页面空闲时每 15 秒自动刷新，也可点击“重新扫描”或手动添加 IP。
- 本机 IPv4 检测支持启动重试、恢复前台后重检和网络设置中的“重新检测”；Wi-Fi/以太网优先于 VMware、VPN 等虚拟网卡。
- 使用统一的 3DS 掌机、CIA 卡带图形与桌面/Android 启动图标；发送完成后显示独立成功结果，可继续发送当前文件或完成并清空。
- Windows 是原生 `.exe`，使用 Flutter + C++，**不需要安装 Java/JRE**。
- Android UI 使用 Flutter，系统文件选择与后台传输使用少量 Kotlin 适配代码，没有 Java 源码。
- 直接流式读取本地文件或 Android `content://` URI，不把数 GB 的 CIA 整体复制到内存或应用缓存。
- 支持 FBI 可识别的 `.cia`、`.tik`、`.cetk`、`.3dsx`。
- HTTP 服务提供固定 `Content-Length`、UTF-8 文件名和单区间 `Range` 请求。
- Android 使用 `dataSync` 前台服务，退到后台后仍可继续传输，并可从通知停止服务。
- 每次共享都会生成随机 URL 令牌；停止服务后链接立即失效。

## 使用

### 扫二维码

1. 手机/电脑和 3DS 连接同一个 Wi-Fi 或局域网。
2. 在 CIA Bridge 中选择一个本地安装文件。
3. 选择“扫码安装”，点击“生成局域网二维码”。
4. 3DS 打开 `FBI → Remote Install → Scan QR Code` 并扫描。
5. 在 FBI 上确认；安装完成前不要停止 CIA Bridge。

### 主动推送给 FBI

1. 3DS 打开 `FBI → Remote Install → Receive URLs over the network`。
2. 在 CIA Bridge 里点选自动识别到的 Nintendo 3DS；Android 如果显示“可能的 Nintendo 3DS”，请选择与 FBI 屏幕 IP 一致的候选。只有列表中确实没有目标时才需要“手动添加”；端口通常是 `5000`。
3. 选中设备后，界面会自动进入文件步骤。
4. 选择文件，点击当前页面中的“发送到 3DS”。
5. 在 3DS 上确认安装。CIA Bridge 会等待 FBI 返回确认字节。

### 自动发现的边界

FBI 没有广播“我正在等待接收”的发现协议。Boop 的做法是从 ARP 表中按 Nintendo 网卡 OUI 找出候选设备，CIA Bridge 在允许读取邻居 MAC 的系统上采用同样的安全思路，并在扫描前用无连接 UDP 预热邻居表。

现代 Android 会阻止普通应用读取其他局域网设备的 MAC，这不是授予定位或“附近设备”权限就能解除的限制。遇到这种系统时，CIA Bridge 会改为扫描同一 `/24` 网段中安全可达的在线地址，并标记为“候选”；候选不代表已经确认是 Nintendo 设备，也不代表 FBI 正处于接收状态，请以 FBI 屏幕显示的 IP 为准。此降级流程仍然不会连接 FBI 的端口。

应用不会通过建立 TCP/5000 连接来测试状态，因为 FBI 会立即接受该连接并等待 4 字节长度；空探测会导致 3DS 弹出读取错误。因此界面中的“局域网可见”表示识别到了 Nintendo 设备，真正的 FBI 接收状态只会在用户点击发送时验证。发送前仍需在 FBI 打开 `Receive URLs over the network`。

## 已生成产物

- `dist/windows/CIA-Bridge-Windows-x64/cia_bridge.exe`：Windows x64 便携版入口。
- `dist/CIA-Bridge-Windows-x64.zip`：完整 Windows 便携包。
- `dist/android/CIA-Bridge-Android-release.apk`：Android release APK（当前使用调试密钥签名，便于直接侧载测试）。

Windows 版本必须保留同目录的 `data`、`flutter_windows.dll` 等文件，不能只复制一个 exe。

## 构建

项目使用 Flutter 3.47.9。当前工作区的 Flutter SDK 位于 `.toolchains/flutter-sdk/flutter`，Android 构建默认复用：

```text
F:\work\music_online_apk\.toolchains\android-sdk
F:\work\music_online_apk\.toolchains\jdk17
```

在 PowerShell 中运行：

```powershell
.\scripts\build-all.ps1 -Clean
```

可通过 `CIA_BRIDGE_FLUTTER`、`ANDROID_HOME`、`JAVA_HOME` 指向其他工具链，也可用 `-SkipWindows` 或 `-SkipAndroid` 只构建一端。脚本会依次运行格式/静态分析、测试、Windows release 和 Android release，并整理 `dist`。

中国大陆网络若不能访问 Google Storage，可设置 Flutter 官方文档列出的 CFUG 镜像：

```powershell
$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
```

## 网络与安全

- HTTP 服务只在用户明确开始共享后监听，并绑定本机 IPv4 网卡。
- URL 使用随机会话令牌，但传输本身是局域网明文 HTTP；不要在不受信任的公共 Wi-Fi 使用。
- Windows 首次监听时，防火墙可能询问权限，只需允许“专用网络”。
- 本工具不提供 CIA 来源或下载目录，只应用于用户有权安装的内容和自制软件。

## 结构

```text
lib/        Flutter UI、状态管理、FBI TCP 客户端、Windows HTTP 服务
android/    Kotlin 文件 URI、流式 HTTP 服务与前台服务适配
windows/    Flutter Windows runner 与原生 C++ 多文件选择器
test/       FBI 协议和 HTTP/Range 自动测试
docs/       协议与架构说明
scripts/    可复现构建与打包脚本
```

详见 [架构说明](docs/ARCHITECTURE.md) 和 [FBI 协议说明](docs/FBI_PROTOCOL.md)。项目自身使用 MIT License，第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

界面流程参考 [LocalSend](https://github.com/localsend/localsend) 的“文件 → 附近设备 → 发送”模型；Nintendo OUI 自动发现思路参考 [Boop](https://github.com/miltoncandelero/Boop)。
