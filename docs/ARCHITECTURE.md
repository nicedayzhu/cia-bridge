# 架构说明

[English](ARCHITECTURE.en.md)

## 数据流

```text
Windows 路径 / Android content:// URI
                 │
                 ▼
       临时局域网 HTTP 服务 ─────────────► FBI 下载并安装
                 ▲                           ▲
                 │ 本机 URL                  │
                 ├──── QR Code ──────────────┤
                 │                           │
                 └──── FBI TCP/5000 推送 ────┘
```

## 分层

- `lib/ui`：Material 3 响应式界面，Windows 使用双栏，窄屏 Android 使用单栏。
- `TransferController`：统一选择文件、网络配置、二维码/推送模式、进度和错误状态。
- `FbiProtocolClient`：纯 Dart 实现 FBI 的 TCP URL 推送协议，两端复用。
- `DeviceDiscovery`：优先广播带版本号的 UDP 请求，精确识别正在等待接收的 CIA Bridge 版 FBI；无回应时预热 `/24` 邻居缓存，继而筛选 Nintendo OUI 或接收 Android 安全可达性候选。
- `DesktopLanServer`：Windows 上的 Dart `HttpServer`，直接流式读取普通文件路径。
- `FileHostBridge`：Flutter 与平台能力之间的窄接口。
- Windows runner：C++ `IFileOpenDialog` 多选文件；不引入 Java 或第三方桌面运行时。
- Windows runner：通过 IP Helper API 读取 IPv4 邻居/ARP 表。
- Android adapter：Kotlin `ACTION_OPEN_DOCUMENT`、`ContentResolver` 流、邻居表读取、安全可达性候选扫描和前台服务。

## 关键设计

- **统一体验**：颜色、排版、文件/设备卡片、状态面板和传输流程全部由一套 Flutter 代码提供。
- **LocalSend 式主流程**：先发现并选择 3DS，再进入选择文件与发送阶段；后续控件不会提前挤在主界面，端口和网卡收进网络设置。
- **无破坏发现**：优先使用 UDP/5001 的明确发现响应；旧版 FBI 无回应时读取邻居信息并匹配 Nintendo OUI，现代 Android 再降级为安全可达候选。任何自动发现路径都不会连接 FBI 的 5000 端口。
- **流式传输**：Windows 使用 `File.openRead`，Android 使用 `ParcelFileDescriptor`/`InputStream`；都不会整体载入 CIA。
- **明确长度**：选取文件时先确定大小，响应写入固定 `Content-Length`，避免分块传输兼容问题。
- **Range**：支持一个 `bytes=start-end`、开放结尾或后缀范围，用于重试/续传。
- **安全路径**：每次服务随机生成 96 位令牌，文件名进行 UTF-8 URL 编码，旧会话停止即失效。
- **端口回退**：首选 HTTP 端口被占用时自动绑定可用端口，并把真实端口写入 QR/推送 URL。
- **生命周期**：扫码模式由用户停止；推送模式等待 FBI 单字节确认。Android 前台服务避免大文件传输被后台限制过早终止。
- **桌面零 JRE**：Windows 产物是 Flutter 原生应用，只随包携带 Flutter DLL 和应用数据，不依赖系统 Java。

## 边界

- 不内置公网下载器、资源站或 CIA 目录。
- 只有 CIA Bridge 版 FBI 能明确回应接收状态；原版和旧版 FBI 仍只能按 Nintendo OUI 或在线候选发现，Android 候选需与 FBI 页面显示的 IP 核对。
- Android 文档提供器如果无法报告文件大小，会拒绝共享，避免发送错误长度。
- QR 容量有限；一次发送多个长 URL 时推荐主动推送模式。
