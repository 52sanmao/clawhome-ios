# Agents Feature Index

[中文版本](./README.md)

Status: Active  
Last Updated: 2026-02-27  
Scope: `clawhome/Features/Agents`

## 1. Goal

This index standardizes the Agent UI plugin directory layout, so `ACP` is no longer treated as a long-term feature boundary.

## 2. Directory Overview (Target Layout)

1. `Shared/`: Reusable timeline/card/rendering foundations for multiple agents.
2. `Claude/`: Claude channel plugin directory (Protocol/Mappers/Cards/Views).
3. `Gemini/`: Gemini channel plugin directory (Protocol/Mappers/Cards/Views).
4. `OpenCode/`: OpenCode channel plugin directory (Protocol/Mappers/Cards/Views).
5. `Codex/`: Codex channel plugin directory (Protocol/Mappers/Cards/Views).
6. `OpenClaw/`: OpenClaw-specific protocol family (non-ACP).
7. `ACP/`: Transition directory for existing implementation; features should be migrated to the directories above.

## 3. Core Protocol Boundaries

1. `Core/Protocols/ACP/`: ACP protocol definitions and decoding (no UI logic).
2. `Core/Network/RelayClient.swift`: Relay transport client (no channel card logic).

## 4. Document Entry

1. `clawhome/Features/Agents/OpenClaw/README-OpenClaw.md`

## 5. Constraints

1. New channel features should be added to `<AgentType>/` first, not `ACP/`.
2. Do not add channel-specific branching in `Shared/`.
3. Do not add rendering copy/card logic in `Core/Protocols/ACP/`.
4. Do not parse channel protocols in `Features/Chat`.
