# ClawHome iOS Quick Start

This guide is for users who want to:

1. Build ClawHome with Xcode.
2. Install it on a real iPhone.
3. Pair it with a locally deployed OpenClaw Gateway.

If you only read one doc, read this one.

## 1) Product Model (Important)

ClawHome is a UI control client.

- It does not run OpenClaw channels by itself.
- It connects to OpenClaw Gateway over WebSocket (`ws://` / `wss://`).
- Channel runtimes are managed by OpenClaw Gateway.
- ClawHome controls OpenClaw through the Gateway RPC/control plane.

Implication:

- If your gateway is only reachable on localhost, your iPhone cannot reach it.
- If you expose it over LAN/Tailscale/Cloudflare, ClawHome can connect remotely.

## 2) Prerequisites

- macOS 14+, Xcode 16+.
- iPhone with Developer Mode enabled.
- OpenClaw installed and running on your Mac/host.
- Optional tools:
  - `qrencode` for terminal QR display.
  - `cloudflared` for public tunnel mode.
  - `tailscale` for tailnet mode.

Install optional tools (macOS Homebrew):

```bash
brew install qrencode cloudflared
# tailscale is usually installed via the official app, not brew
```

## 3) Build and Install to iPhone (Xcode)

1. Clone and open project:

```bash
git clone https://github.com/yeyitech/clawhome-ios.git
cd clawhome-ios
open clawhome.xcodeproj
```

2. In Xcode:

- Select project `clawhome`.
- Select target `clawhome`.
- Open `Signing & Capabilities`.
- Set a unique `Bundle Identifier` (for your Apple account).
- Select your Apple Team.
- Keep `Automatically manage signing` enabled.

3. Connect iPhone and run:

- Select your iPhone as run destination.
- Click Run.

4. Trust developer certificate on iPhone (first install only):

- `Settings -> General -> VPN & Device Management -> Developer App -> Trust`.

## 4) Start OpenClaw Gateway

Common modes:

- Local-only (same machine): default bind is loopback.
- LAN mode (same Wi-Fi/LAN): gateway must bind LAN.
- Public internet mode: use Cloudflare Tunnel or Tailscale Funnel/Serve.

Example (LAN, token auth):

```bash
openclaw gateway --bind lan --auth token --token '<LONG_RANDOM_TOKEN>'
```

## 5) Generate Pairing URL + QR (Recommended Script)

Use the included script:

```bash
scripts/openclaw-pair.sh --exposure lan
```

Other modes:

```bash
scripts/openclaw-pair.sh --exposure local
scripts/openclaw-pair.sh --exposure cloudflare
scripts/openclaw-pair.sh --exposure tailscale
```

### What this script auto-detects

- OpenClaw config path:
  - `OPENCLAW_CONFIG_PATH`
  - `OPENCLAW_STATE_DIR/openclaw.json` (and legacy filenames)
  - default paths (`~/.openclaw/openclaw.json`, legacy dirs)
- Gateway settings:
  - `gateway.bind`
  - `gateway.port`
  - `gateway.auth.mode`
- Auth secrets (with OpenClaw precedence style):
  - `OPENCLAW_GATEWAY_TOKEN` / `OPENCLAW_GATEWAY_PASSWORD`
  - fallback to `gateway.auth.token` / `gateway.auth.password`

The script outputs a ClawHome-compatible URL and terminal QR code.

Help:

```bash
scripts/openclaw-pair.sh --help
```

## 6) Pair in ClawHome App

On iPhone:

1. Open ClawHome.
2. Tap `+`.
3. Tap `Scan QR Code`.
4. Scan terminal QR from `openclaw-pair.sh`.
5. Save gateway and open a session.

## 7) Network Exposure Choices

`local`

- URL shape: `ws://127.0.0.1:<port>?token=...`
- Works for simulator on the same machine, not for iPhone on Wi-Fi.

`lan`

- URL shape: `ws://<LAN_IP>:<port>?token=...`
- iPhone and gateway host must be on reachable LAN.
- Gateway bind must be LAN-capable (`gateway.bind=lan` or equivalent).

`cloudflare`

- URL shape: `wss://<random>.trycloudflare.com?token=...`
- Works across the internet.
- Tunnel process must stay alive.
- Use strong auth token/password.

`tailscale`

- URL shape: `ws://<TAILSCALE_IP>:<port>?token=...`
- Requires both devices in same tailnet.
- Usually needs `gateway.bind=tailnet` (or OpenClaw tailscale serve/funnel setup).

## 8) Security Checklist

- Do not commit gateway token/password to git.
- Prefer env vars for secrets:
  - `OPENCLAW_GATEWAY_TOKEN`
  - `OPENCLAW_GATEWAY_PASSWORD`
- Use long random secrets (especially for public exposure).
- Rotate secrets if they are shared in logs/screenshots.

## 9) Troubleshooting

- `openclaw-pair.sh` says `openclaw CLI not found`
  - Install OpenClaw CLI and ensure `openclaw` is in `PATH`.
- LAN connection timeout
  - Gateway is likely loopback-only. Restart with LAN bind.
- Cloudflare URL not generated
  - Install `cloudflared` and retry.
  - Check tunnel log path printed by script.
- Tailscale mode fails
  - Ensure `tailscale` is installed, logged in, and gateway bind mode is compatible.
