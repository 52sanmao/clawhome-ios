# OpenClaw UI Capability Map

[English Version](./README-OpenClaw.en.md)

状态：Active  
最后更新：2026-02-27  
适用范围：`clawhome/Features/Agents/OpenClaw` 与 `clawhome/Features/Chat` 的 OpenClaw 分支

## 1. 协议定位

OpenClaw 是 iOS 侧独立协议族，不走 CLI ACP 通道：

1. 网络入口：`clawhome/Core/Network/OpenClawClient.swift`
2. 连接管理：`clawhome/Core/Services/ConnectionManager.swift`
3. 会话列表入口：`clawhome/Features/Agents/OpenClaw/Views/OpenClawSessionListView.swift`

## 2. Chat 页面 UI 能力（当前已支持）

### 2.1 输入框上方功能按钮

按钮来自 `ChatToolbar`，仅当 `bot.channelType == .openClaw` 时注入回调：

1. `技能` -> `OpenClawSkillsSheet`
2. `Token` -> `UsageStatisticsView`
3. `定时任务` -> `CronJobsView`
4. `设置` -> `ModelConfigView`
5. `思考` -> `ThinkingLevelSheet`

代码入口：`clawhome/Features/Chat/Views/ChatView.swift`、`clawhome/Features/Chat/Views/ChatToolbar.swift`

### 2.2 输入区

1. 统一使用 `ChatInputBar`（文本、语音、附件、停止运行）。
2. OpenClaw 会通过 `ChatViewModel` 注入 run 控制与附件上传能力。

代码入口：`clawhome/Features/Chat/Views/ChatInputBar.swift`、`clawhome/Features/Chat/ViewModels/ChatViewModel.swift`

## 3. OpenClaw 专属页面

1. `OpenClawSessionListView.swift`：多会话列表与新建会话。
2. `OpenClawSkillsSheet.swift`：技能开关。
3. `UsageStatisticsView.swift`：Token/用量统计。
4. `CronJobsView.swift`：定时任务管理。
5. `ModelConfigView.swift`：模型配置。
6. `ThinkingLevelSheet.swift`：思考等级设置。

## 4. OpenClaw 展示语义层

1. `Models/SkillDisplay.swift`：`Skill` 的 UI 状态与展示文案计算。
2. `Models/CronJobDisplay.swift`：Cron 表达式可读化展示。
3. `Models/UsageCostDisplay.swift`：Token/成本格式化展示。

## 5. 能力边界

1. OpenClaw 的会话、RPC、工具状态由 OpenClaw 协议自身决定，不映射 CLI ACP 的 `tool_call/tool_call_update`。
2. Chat 壳层复用是允许的；协议解析与状态机不混写到 CLI 目录。
3. `Core/Network/Models` 只保留 DTO；OpenClaw 专属展示逻辑统一放在 `Features/Agents/OpenClaw/Models`。
4. 新增 OpenClaw 功能时，先改本 README，再改 `Features/Agents/OpenClaw` 对应视图或 `OpenClawClient`。

## 6. 验收清单

1. 打开 OpenClaw Chat 时，`ChatToolbar` 五个按钮按需显示。
2. `recordingState != idle` 时上方按钮自动隐藏（与通用输入壳层一致）。
3. Skills/Token/Cron/Settings/Thinking 五个 sheet 能独立打开且互不干扰。
