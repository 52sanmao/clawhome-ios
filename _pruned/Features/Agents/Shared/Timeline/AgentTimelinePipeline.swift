//
//  AgentTimelinePipeline.swift
//  contextgo
//
//  Unified parser contracts: raw protocol payload -> timeline items.
//

import Foundation

struct AgentRawEventEnvelope: Codable, Equatable {
    let sessionId: String
    let seq: Int?
    let timestamp: Date
    let agentType: AgentChannelType
    let eventType: String?
    let payload: String

    init(
        sessionId: String,
        seq: Int? = nil,
        timestamp: Date = Date(),
        agentType: AgentChannelType,
        eventType: String? = nil,
        payload: String
    ) {
        self.sessionId = sessionId
        self.seq = seq
        self.timestamp = timestamp
        self.agentType = agentType
        self.eventType = eventType
        self.payload = payload
    }
}

protocol AgentTimelineParser {
    var agentType: AgentChannelType { get }
    func buildItems(from rawEvent: AgentRawEventEnvelope) -> [AgentTimelineItem]
}

struct DefaultRawTimelineParser: AgentTimelineParser {
    let agentType: AgentChannelType

    func buildItems(from rawEvent: AgentRawEventEnvelope) -> [AgentTimelineItem] {
        let title = rawEvent.eventType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            AgentTimelineItem(
                sessionId: rawEvent.sessionId,
                seq: rawEvent.seq,
                agentType: rawEvent.agentType,
                timestamp: rawEvent.timestamp,
                kind: .rawEvent,
                title: (title?.isEmpty == false) ? title : "raw.event",
                text: nil,
                rawPayload: rawEvent.payload
            )
        ]
    }
}

enum AgentTimelineParserRegistry {
    static func resolve(for agentType: AgentChannelType) -> any AgentTimelineParser {
        switch agentType {
        case .claudeCode:
            ClaudeTimelineParser()
        case .codex:
            CodexTimelineParser()
        case .openCode:
            OpenCodeTimelineParser()
        case .geminiCLI:
            GeminiTimelineParser()
        case .openClaw:
            DefaultRawTimelineParser(agentType: .openClaw)
        }
    }
}
