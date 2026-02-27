# ClawHome iOS

[中文说明](./README.zh-CN.md)

ClawHome iOS is a lightweight UI control app for OpenClaw.
It connects to an OpenClaw Gateway over WebSocket (`ws://` / `wss://`) and focuses on session browsing + chat UI.

This repository is intentionally **UI-only**:
- No OpenClaw server runtime is bundled here
- No backend deployment logic is bundled here
- No production credentials are committed

## Positioning

ClawHome iOS is for operators who already have an OpenClaw Gateway endpoint and want a native iOS control panel.

## Features

- Multi-gateway management (add/edit/delete)
- QR code onboarding and manual URL entry
- OpenClaw session list and chat UI
- Local session cache (GRDB)
- Optional voice transcription with Alibaba DashScope ASR

## Requirements

- macOS 14+ and Xcode 16+
- iOS 18.5+ Simulator or device
- A running OpenClaw Gateway endpoint (for example `ws://127.0.0.1:18789`)

## Quick Start

1. Start your OpenClaw Gateway

Make sure your gateway is reachable from your iPhone/Simulator.
Use either:
- `ws://<host>:<port>`
- `wss://<host>/<path>?secret=<YOUR_SECRET>`

`secret`, `token`, and `password` query parameters are all supported by the client.

2. Clone and open the project

```bash
git clone https://github.com/yeyitech/clawhome-ios.git
cd clawhome-ios
open clawhome.xcodeproj
```

3. (Optional) Configure Alibaba DashScope ASR key

If you only need text chat, skip this step.

For voice input/transcription, set one of:
- Environment variable: `ASR_DASHSCOPE_API_KEY`
- Info.plist key: `ASR_DASHSCOPE_API_KEY`

Optional WebSocket override:
- Environment variable: `ASR_DASHSCOPE_WS_URL`
- Info.plist key: `ASR_DASHSCOPE_WS_URL`

Default ASR WebSocket endpoint:
- `wss://dashscope.aliyuncs.com/api-ws/v1/inference/`

4. Build and run

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

5. Add Gateway in app

- Tap `+` on home
- Paste or scan your OpenClaw WebSocket URL
- Enter a display name and save
- Open a session and start chatting

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
- Voice input reports missing key:
  - Set `ASR_DASHSCOPE_API_KEY` in Run Scheme environment or Info.plist
- Build/signing issues on your machine:
  - Build simulator with `CODE_SIGNING_ALLOWED=NO`
  - For real device, set your own Apple Team in Xcode Signing settings
