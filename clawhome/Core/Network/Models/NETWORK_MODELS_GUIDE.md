# Core Network Models

[English Version](./NETWORK_MODELS_GUIDE.en.md)

状态：Active  
最后更新：2026-02-27  
适用范围：`clawhome/Core/Network/Models`

该目录仅存放网络传输 DTO（HTTP/RPC/WebSocket 请求与响应模型）。

约束：
- 不在此目录放 UI 渲染语义（标题、颜色、展示文案、排序策略）。
- 不在此目录放页面格式化逻辑（如日期/成本显示格式）。
- 允许保留协议兼容解码逻辑与结构转换辅助。

展示相关扩展统一放到 `Features/Agents/<AgentType>/Models`。
