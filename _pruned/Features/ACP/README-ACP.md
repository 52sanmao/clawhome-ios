# CLI Agents (ACP Family)

状态：Active  
最后更新：2026-02-22  
适用范围：`contextgo-ios/contextgo/Features/Agents/ACP`

## 1. 目标

`ACP/` 目录当前承载四类 Agent 的存量统一协议渲染链路：

1. Claude Code
2. Codex
3. Gemini CLI
4. OpenCode

目录定位已调整为“迁移过渡层”。新功能应优先进入：

1. `contextgo/Features/Agents/Claude/`
2. `contextgo/Features/Agents/Gemini/`
3. `contextgo/Features/Agents/OpenCode/`
4. `contextgo/Features/Agents/Codex/`

## 2. 运行链路

1. 入站协议归一：`contextgo/Core/Network/RelayClient.swift`
2. 会话状态聚合：`contextgo/Features/Agents/ACP/ViewModels/CLISessionViewModel.swift`
3. 协议语义基线（parse）：`contextgo/Features/Agents/ACP/Models/CLIMessage.swift`（`CLIToolSemantics`）
4. run 分组与消息编排：`contextgo/Features/Agents/ACP/Views/CLIProtocolRender.swift`
5. 工具卡片语义与组件：`contextgo/Features/Agents/ACP/Views/ToolCards/`
6. 未映射协议事件兜底卡片：`ProtocolFallbackToolCardContentView`（位于 `ToolCards/`）

## 3. 目录分工

1. `Models/`：协议模型 + 语义分类。
2. `Services/`：语音输入、加密、终端鉴权等会话服务。
3. `ViewModels/`：会话状态、远程同步、权限动作。
4. `Views/`：会话页面、运行分组、工具卡片 UI。

## 5. Local / Remote 接管

iOS 侧会话页支持接管模式切换：

1. 配置入口：`contextgo/Features/Agents/ACP/Views/CLISessionSettings.swift`
2. 运行态标识：`contextgo/Features/Agents/ACP/Views/SessionDetailView.swift`
3. RPC 写入字段：`mode = local | remote`（通过 session config 更新）

## 6. 回放状态

当前版本已移除 ACP fixture 回放入口与对应 UI 调试菜单，协议验证以真实会话链路为准。
