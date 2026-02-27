# OpenClaw UI Capability Map

[中文版本](./README-OpenClaw.md)

Status: Active  
Last Updated: 2026-02-27  
Scope: OpenClaw branch under `clawhome/Features/Agents/OpenClaw` and `clawhome/Features/Chat`

## 1. Protocol Positioning

OpenClaw is an independent protocol family on iOS and does not use the CLI ACP channel.

1. Network entry: `clawhome/Core/Network/OpenClawClient.swift`
2. Connection manager: `clawhome/Core/Services/ConnectionManager.swift`
3. Session list entry: `clawhome/Features/Agents/OpenClaw/Views/OpenClawSessionListView.swift`

## 2. Chat UI Capabilities (Current)

### 2.1 Function Buttons Above Input

Buttons come from `ChatToolbar` and are injected only when `bot.channelType == .openClaw`:

1. `Skills` -> `OpenClawSkillsSheet`
2. `Token` -> `UsageStatisticsView`
3. `Cron` -> `CronJobsView`
4. `Settings` -> `ModelConfigView`
5. `Thinking` -> `ThinkingLevelSheet`

Code entry points: `clawhome/Features/Chat/Views/ChatView.swift`, `clawhome/Features/Chat/Views/ChatToolbar.swift`

### 2.2 Input Area

1. Always uses `ChatInputBar` (text, voice, attachment, stop-run).
2. OpenClaw injects run-control and attachment upload via `ChatViewModel`.

Code entry points: `clawhome/Features/Chat/Views/ChatInputBar.swift`, `clawhome/Features/Chat/ViewModels/ChatViewModel.swift`

## 3. OpenClaw-specific Screens

1. `OpenClawSessionListView.swift`: Multi-session list and session creation.
2. `OpenClawSkillsSheet.swift`: Skill toggles.
3. `UsageStatisticsView.swift`: Token/usage statistics.
4. `CronJobsView.swift`: Scheduled-job management.
5. `ModelConfigView.swift`: Model configuration.
6. `ThinkingLevelSheet.swift`: Thinking level control.

## 4. OpenClaw Presentation Semantics Layer

1. `Models/SkillDisplay.swift`: UI state and display-copy mapping for `Skill`.
2. `Models/CronJobDisplay.swift`: Human-readable cron expression display.
3. `Models/UsageCostDisplay.swift`: Token/cost formatting.

## 5. Capability Boundaries

1. OpenClaw sessions, RPC and tool states are defined by the OpenClaw protocol itself, not mapped from CLI ACP `tool_call/tool_call_update`.
2. Reusing Chat shell/UI is allowed; protocol parsing and state machine must not be mixed into CLI directories.
3. `Core/Network/Models` should only keep DTOs; OpenClaw-specific presentation logic belongs in `Features/Agents/OpenClaw/Models`.
4. When adding OpenClaw features, update this README first, then update related views or `OpenClawClient`.

## 6. Acceptance Checklist

1. In OpenClaw chat, five `ChatToolbar` buttons are displayed as expected.
2. When `recordingState != idle`, top buttons are hidden automatically (same behavior as shared input shell).
3. The five sheets (Skills/Token/Cron/Settings/Thinking) can open independently without interfering with each other.
