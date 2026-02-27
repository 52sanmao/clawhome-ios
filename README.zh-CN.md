# ClawHome iOS

[English README](./README.md)
[Quick Start (English)](./docs/QUICKSTART.md) | [Quick Start（中文）](./docs/QUICKSTART.zh-CN.md)

ClawHome iOS 是一个轻量级的 OpenClaw 控制端。
它通过 WebSocket（`ws://` / `wss://`）连接 OpenClaw Gateway，核心能力是会话列表与聊天 UI 展示。

本仓库刻意保持为 **纯 UI 客户端**：
- 不包含 OpenClaw 服务端运行时
- 不包含后端部署逻辑
- 不提交任何生产密钥

## 项目定位

当你已经有 OpenClaw Gateway 地址时，ClawHome iOS 提供一个原生 iOS 控制面板来进行会话查看与交互。

OpenClaw 的各类 Channel（如 WhatsApp/Telegram 等）运行在 OpenClaw Gateway 进程内。
ClawHome 不承载 Channel 运行时，只连接 Gateway 的 WebSocket RPC 控制面。
因此 ClawHome 能控制整套 OpenClaw，但前提是你的 iPhone 能访问到 Gateway 地址。

## 功能特性

- 多 Gateway 管理（新增/编辑/删除）
- 支持二维码接入和手动输入地址
- OpenClaw 会话列表与聊天界面
- 本地会话缓存（GRDB）
- 可选语音转写（阿里云 DashScope ASR）

## 环境要求

- macOS 14+，Xcode 16+
- iOS 18.5+ 模拟器或真机
- 可访问的 OpenClaw Gateway

## Quick Start（可直接跑通）

1. 拉取代码并打开工程

```bash
git clone https://github.com/yeyitech/clawhome-ios.git
cd clawhome-ios
open clawhome.xcodeproj
```

2. 用 Xcode 安装到真机

- 选中项目 `clawhome` -> target `clawhome` -> `Signing & Capabilities`
- 设置你自己的唯一 `Bundle Identifier`
- 选择你的 Apple Team，保持 `Automatically manage signing` 开启
- 连接 iPhone，选择该设备为运行目标，点击 Run
- 首次启动需在 iPhone 上信任开发者证书：
  `设置 -> 通用 -> VPN 与设备管理 -> 开发者 App -> 信任`

3. 启动 OpenClaw 并生成配对二维码

- 局域网配对：
  `scripts/openclaw-pair.sh --exposure lan`
- Cloudflare Tunnel（公网）配对：
  `scripts/openclaw-pair.sh --exposure cloudflare`
- Tailscale 配对：
  `scripts/openclaw-pair.sh --exposure tailscale`

脚本会自动检测：
- OpenClaw 配置文件路径
- `gateway.auth.mode`
- `gateway.auth.token` / `gateway.auth.password`（环境变量优先）

随后输出可被 ClawHome 直接识别的 `ws://` 或 `wss://` 地址，并在终端渲染二维码。

4. 在 App 中扫码

- iPhone 打开 ClawHome
- 点击 `+` -> `Scan QR Code`
- 保存网关并进入会话

5. （可选）配置阿里云 DashScope ASR Key

如果你只用文本聊天，可以跳过。

如需语音输入/转写，配置以下任一来源：
- 环境变量：`ASR_DASHSCOPE_API_KEY`
- Info.plist 键：`ASR_DASHSCOPE_API_KEY`

可选覆盖 ASR WebSocket 地址：
- 环境变量：`ASR_DASHSCOPE_WS_URL`
- Info.plist 键：`ASR_DASHSCOPE_WS_URL`

默认 ASR WebSocket 地址：
- `wss://dashscope.aliyuncs.com/api-ws/v1/inference/`

6. 命令行构建（可选）

Xcode 中：
- 选择 `clawhome` Scheme
- 运行到 iOS 模拟器

命令行（无签名构建）：

```bash
xcodebuild -resolvePackageDependencies \
  -project clawhome.xcodeproj \
  -scheme clawhome

xcodebuild \
  -project clawhome.xcodeproj \
  -scheme clawhome \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 安全与开源状态

- 源码不包含硬编码 API Key
- 签名配置已改为开源协作友好配置
- GitHub Actions 为纯构建 CI，不依赖 TestFlight/App Store 密钥
- 连接日志会脱敏 URL 中的凭据参数

## CI

工作流：`.github/workflows/ios-ci.yml`
- 自动解析 Swift 包依赖
- 使用 `CODE_SIGNING_ALLOWED=NO` 进行模拟器构建

## 目录结构

- `clawhome/Features/ClawHome/`：首页、网关管理、二维码接入
- `clawhome/Features/Chat/`：聊天 UI 与 ViewModel
- `clawhome/Core/Network/`：OpenClaw/WebSocket 网络层
- `clawhome/Core/Storage/`：本地会话与消息缓存
- `clawhome/Core/Services/FileASRService.swift`：可选 ASR 能力

## 常见问题

- 无法连接 Gateway：
  - 确认 URL 协议是 `ws://` 或 `wss://`
  - 确认设备到网关主机/端口网络可达
  - 如使用鉴权，确认 `secret`/`token`/`password` 参数值正确
- 局域网配对超时：
  - 你的 Gateway 大概率仍是 `loopback` 绑定
  - 用 LAN 绑定重启后重新生成二维码：
    `openclaw gateway --bind lan --auth token --token '<高强度随机令牌>'`
- Cloudflare 配对失败：
  - 安装 `cloudflared` 后重试：
    `brew install cloudflared`
- 语音提示未配置 Key：
  - 在运行 Scheme 环境变量或 Info.plist 中设置 `ASR_DASHSCOPE_API_KEY`
- 本机签名报错：
  - 模拟器构建使用 `CODE_SIGNING_ALLOWED=NO`
  - 真机构建请在 Xcode Signing 中设置你自己的 Apple Team
