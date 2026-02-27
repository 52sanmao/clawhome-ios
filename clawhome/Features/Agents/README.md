# Agents Feature Index

[English Version](./README.en.md)

状态：Active  
最后更新：2026-02-27  
适用范围：`clawhome/Features/Agents`

## 1. 目标

本索引用于统一 Agent UI 插件化目录，避免继续以 `ACP` 作为长期功能边界。

## 2. 目录总览（当前目标框架）

1. `Shared/`：多 Agent 复用的 Timeline/Card/Rendering 基础能力。
2. `Claude/`：Claude 渠道插件目录（Protocol/Mappers/Cards/Views）。
3. `Gemini/`：Gemini 渠道插件目录（Protocol/Mappers/Cards/Views）。
4. `OpenCode/`：OpenCode 渠道插件目录（Protocol/Mappers/Cards/Views）。
5. `Codex/`：Codex 渠道插件目录（Protocol/Mappers/Cards/Views）。
6. `OpenClaw/`：OpenClaw 独立协议族（非 ACP）。
7. `ACP/`：迁移过渡目录，承载当前存量实现，后续逐步拆分到上面各目录。

## 3. Core 协议边界

1. `Core/Protocols/ACP/`：ACP 协议层定义与解码（无 UI）。
2. `Core/Network/RelayClient.swift`：Relay 传输客户端（无渠道卡片逻辑）。

## 4. 文档入口

1. `clawhome/Features/Agents/OpenClaw/README-OpenClaw.md`

## 5. 约束

1. 新增渠道代码优先放 `<AgentType>/`，不再新增到 `ACP/`。
2. 不在 `Shared/` 写渠道特判。
3. 不在 `Core/Protocols/ACP/` 写渲染文案或卡片逻辑。
4. 不在 `Features/Chat` 写具体渠道协议解析。
