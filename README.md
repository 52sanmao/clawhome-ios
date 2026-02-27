# ClawHome iOS

[中文说明](./README.zh-CN.md)
[Quick Start (EN)](./docs/QUICKSTART.md) | [Quick Start (中文)](./docs/QUICKSTART.zh-CN.md)

ClawHome iOS is a lightweight UI control app for OpenClaw.
It connects to an OpenClaw Gateway over WebSocket (`ws://` / `wss://`) and focuses on session browsing + chat UI.

This repository is intentionally **UI-only**:
- No OpenClaw server runtime is bundled here
- No backend deployment logic is bundled here
- No production credentials are committed

## Positioning

ClawHome iOS is for operators who already have an OpenClaw Gateway endpoint and want a native iOS control panel.

OpenClaw channels (WhatsApp/Telegram/etc.) run inside OpenClaw Gateway itself.
ClawHome does not host channel runtimes. It only connects to the Gateway WebSocket RPC control plane.
That means ClawHome can control the whole OpenClaw instance, but only when the Gateway endpoint is reachable from your phone.

## Features

- Multi-gateway management (add/edit/delete)
- QR code onboarding and manual URL entry
- OpenClaw session list and chat UI
- Local session cache (GRDB)
- Optional voice transcription with Alibaba DashScope ASR

## Requirements

- macOS 14+ and Xcode 16+
- iOS 18.5+ Simulator or device
- A running OpenClaw Gateway endpoint

## Quick Start

1. Clone and open the project

```bash
git clone https://github.com/yeyitech/clawhome-ios.git
cd clawhome-ios
open clawhome.xcodeproj
```

2. Install to a real iPhone in Xcode

- Select project `clawhome` -> target `clawhome` -> `Signing & Capabilities`
- Set your own `Bundle Identifier` (must be unique)
- Select your Apple Team and keep `Automatically manage signing` enabled
- Connect your iPhone, choose it as the run destination, then press Run
- On first launch, trust the developer profile on iPhone:
  `Settings -> General -> VPN & Device Management -> Developer App -> Trust`

3. Start OpenClaw and generate a pairing QR

- LAN pairing:
  `scripts/openclaw-pair.sh --exposure lan`
- Cloudflare Tunnel pairing (public URL):
  `scripts/openclaw-pair.sh --exposure cloudflare`
- Tailscale pairing:
  `scripts/openclaw-pair.sh --exposure tailscale`

The script auto-detects:
- OpenClaw config path
- `gateway.auth.mode`
- `gateway.auth.token` / `gateway.auth.password` (env overrides take precedence)

Then it prints a ClawHome-compatible `ws://` or `wss://` URL and renders a terminal QR.

4. Scan in app

- Open ClawHome on iPhone
- Tap `+` -> `Scan QR Code`
- Save the gateway and open a session

5. (Optional) Configure Alibaba DashScope ASR key

If you only need text chat, skip this step.

For voice input/transcription, set one of:
- Environment variable: `ASR_DASHSCOPE_API_KEY`
- Info.plist key: `ASR_DASHSCOPE_API_KEY`

Optional WebSocket override:
- Environment variable: `ASR_DASHSCOPE_WS_URL`
- Info.plist key: `ASR_DASHSCOPE_WS_URL`

Default ASR WebSocket endpoint:
- `wss://dashscope.aliyuncs.com/api-ws/v1/inference/`

6. Build from command line (optional)

Using Xcode:
- Select scheme `clawhome`
- Run on iOS Simulator

Or from command line:

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

## Security & Open Source Readiness

- No hardcoded API keys in source
- Signing config is genericized for open-source collaboration
- CI workflow is build-only (no TestFlight/App Store credentials)
- WebSocket credential query strings are redacted in connection logs

## CI

GitHub Actions workflow: `.github/workflows/ios-ci.yml`
- Resolves Swift packages
- Builds simulator target with `CODE_SIGNING_ALLOWED=NO`

## Project Structure

- `clawhome/Features/ClawHome/`: Home, gateway management, QR onboarding
- `clawhome/Features/Chat/`: Chat UI and ViewModel
- `clawhome/Core/Network/`: OpenClaw/WebSocket networking
- `clawhome/Core/Storage/`: Local session and message storage
- `clawhome/Core/Services/FileASRService.swift`: Optional ASR integration

## Troubleshooting

- Cannot connect:
  - Verify the gateway URL scheme is `ws://` or `wss://`
  - Verify device/simulator can reach gateway host and port
  - If using auth, verify `secret`/`token`/`password` query value
- LAN pairing fails with timeout:
  - Your gateway is likely still loopback-only
  - Restart gateway with LAN bind, then regenerate QR:
    `openclaw gateway --bind lan --auth token --token '<LONG_RANDOM_TOKEN>'`
- Cloudflare pairing fails:
  - Install `cloudflared` and rerun:
    `brew install cloudflared`
- Voice input reports missing key:
  - Set `ASR_DASHSCOPE_API_KEY` in Run Scheme environment or Info.plist
- Build/signing issues on your machine:
  - Build simulator with `CODE_SIGNING_ALLOWED=NO`
  - For real device, set your own Apple Team in Xcode Signing settings
