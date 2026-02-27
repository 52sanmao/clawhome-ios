# Core Network Models

[中文版本](./NETWORK_MODELS_GUIDE.md)

Status: Active  
Last Updated: 2026-02-27  
Scope: `clawhome/Core/Network/Models`

This directory stores transport DTOs only (HTTP/RPC/WebSocket request/response models).

Constraints:

- Do not place UI semantics here (titles, colors, display copy, sorting rules).
- Do not place page-level formatting logic here (date/cost formatting, etc.).
- Protocol compatibility decoding and structural conversion helpers are allowed.

Presentation-related extensions must live under `Features/Agents/<AgentType>/Models`.
