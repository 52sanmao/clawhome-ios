# ClawHome iOS 快速开始

本指南面向以下目标：

1. 用 Xcode 编译 ClawHome。
2. 安装到自己的 iPhone。
3. 与本地部署的 OpenClaw Gateway 完成配对。

如果只看一份文档，请看这一份。

## 1）先理解项目模型（重要）

ClawHome 是 UI 控制客户端。

- 它本身不运行 OpenClaw 的 channel 进程。
- 它通过 WebSocket（`ws://` / `wss://`）连接 OpenClaw Gateway。
- 各类 channel 运行时都在 OpenClaw Gateway 内。
- ClawHome 通过 Gateway 的 RPC/控制面来控制整个 OpenClaw。

这意味着：

- 如果 Gateway 只监听 localhost，iPhone 无法访问。
- 只要通过 LAN / Tailscale / Cloudflare 暴露可达地址，ClawHome 就能远程接入。

## 2）环境准备

- macOS 14+，Xcode 16+。
- iPhone（已开启开发者模式）。
- 你的 Mac/主机已安装并可运行 OpenClaw。
- 可选工具：
  - `qrencode`：终端显示二维码。
  - `cloudflared`：Cloudflare Tunnel 公网模式。
  - `tailscale`：内网穿透 / Tailnet 模式。

macOS（Homebrew）可选安装示例：

```bash
brew install qrencode cloudflared
# tailscale 通常通过官方 App 安装
```

## 3）Xcode 真机安装步骤

1. 拉取并打开工程：

```bash
git clone https://github.com/yeyitech/clawhome-ios.git
cd clawhome-ios
open clawhome.xcodeproj
```

2. 在 Xcode 内设置签名：

- 选择项目 `clawhome`。
- 选择 target `clawhome`。
- 打开 `Signing & Capabilities`。
- 设置唯一的 `Bundle Identifier`（你的 Apple 账号下不能冲突）。
- 选择你的 Apple Team。
- 保持 `Automatically manage signing` 开启。

3. 连接 iPhone 并运行：

- 选择你的 iPhone 作为运行目标。
- 点击 Run。

4. 首次安装信任开发者证书：

- `设置 -> 通用 -> VPN 与设备管理 -> 开发者 App -> 信任`。

## 4）启动 OpenClaw Gateway

常见模式：

- 本机模式（仅同机访问）：默认 loopback。
- 局域网模式（同 Wi-Fi/LAN）：需要 LAN 绑定。
- 公网模式：通过 Cloudflare Tunnel 或 Tailscale Funnel/Serve。

示例（LAN + token 鉴权）：

```bash
openclaw gateway --bind lan --auth token --token '<高强度随机令牌>'
```

## 5）生成配对地址与二维码（推荐脚本）

使用仓库内脚本：

```bash
scripts/openclaw-pair.sh --exposure lan
```

其他模式：

```bash
scripts/openclaw-pair.sh --exposure local
scripts/openclaw-pair.sh --exposure cloudflare
scripts/openclaw-pair.sh --exposure tailscale
```

### 脚本会自动检测什么

- OpenClaw 配置路径：
  - `OPENCLAW_CONFIG_PATH`
  - `OPENCLAW_STATE_DIR/openclaw.json`（含历史文件名兼容）
  - 默认路径（`~/.openclaw/openclaw.json`，及历史目录）
- 网关配置：
  - `gateway.bind`
  - `gateway.port`
  - `gateway.auth.mode`
- 鉴权密钥（遵循 OpenClaw 常见优先级）：
  - `OPENCLAW_GATEWAY_TOKEN` / `OPENCLAW_GATEWAY_PASSWORD`
  - 回退读取 `gateway.auth.token` / `gateway.auth.password`

脚本会输出可被 ClawHome 直接识别的 URL，并在终端渲染二维码。

帮助：

```bash
scripts/openclaw-pair.sh --help
```

## 6）在 ClawHome 中完成配对

iPhone 侧步骤：

1. 打开 ClawHome。
2. 点击 `+`。
3. 点击 `Scan QR Code`。
4. 扫描 `openclaw-pair.sh` 输出的终端二维码。
5. 保存网关并进入会话。

## 7）网络接入方式说明

`local`

- 地址形态：`ws://127.0.0.1:<port>?token=...`
- 适合同机模拟器，不适合同 Wi-Fi 的独立 iPhone。

`lan`

- 地址形态：`ws://<局域网IP>:<port>?token=...`
- iPhone 与网关主机需网络互通。
- Gateway 必须支持 LAN 绑定（如 `gateway.bind=lan`）。

`cloudflare`

- 地址形态：`wss://<随机子域>.trycloudflare.com?token=...`
- 可跨公网访问。
- Tunnel 进程必须保持运行。
- 必须使用高强度 token/password。

`tailscale`

- 地址形态：`ws://<TAILSCALE_IP>:<port>?token=...`
- 要求手机与主机在同一 tailnet。
- 通常需要 `gateway.bind=tailnet`（或已配置 OpenClaw tailscale serve/funnel）。

## 8）安全检查清单

- 不要把 gateway token/password 提交到 git。
- 优先使用环境变量保存密钥：
  - `OPENCLAW_GATEWAY_TOKEN`
  - `OPENCLAW_GATEWAY_PASSWORD`
- 公网暴露场景务必使用长随机密钥。
- 如果截图/日志泄露了密钥，立即轮换。

## 9）故障排查

- `openclaw-pair.sh` 提示找不到 `openclaw`
  - 安装 OpenClaw CLI，并确保 `openclaw` 在 `PATH` 中。
- LAN 连接超时
  - Gateway 大概率仍为 loopback 绑定，改为 LAN 绑定后重试。
- Cloudflare 未生成公网地址
  - 安装 `cloudflared` 后重试。
  - 查看脚本输出的 tunnel 日志路径。
- Tailscale 模式失败
  - 确认 `tailscale` 已安装并登录，且 gateway bind 模式匹配。
