//
//  AgentTimelineItem.swift
//  contextgo
//
//  Channel-agnostic timeline model routed by concrete Agent runtime type.
//

import Foundation

enum AgentTimelineItemKind: String, Codable {
    case markdown
    case toolState
    case todoSnapshot
    case status
    case rawEvent
}

struct AgentTimelineItem: Identifiable, Codable, Equatable {
    let id: String
    let sessionId: String
    let seq: Int?
    let agentType: AgentChannelType
    let timestamp: Date
    let kind: AgentTimelineItemKind
    let title: String?
    let text: String?
    let rawPayload: String?

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        seq: Int? = nil,
        agentType: AgentChannelType,
        timestamp: Date = Date(),
        kind: AgentTimelineItemKind,
        title: String? = nil,
        text: String? = nil,
        rawPayload: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.seq = seq
        self.agentType = agentType
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.text = text
        self.rawPayload = rawPayload
    }
}
