import Foundation

struct ClaudeTimelineParser: AgentTimelineParser {
    let agentType: AgentChannelType = .claudeCode

    func buildItems(from rawEvent: AgentRawEventEnvelope) -> [AgentTimelineItem] {
        DefaultRawTimelineParser(agentType: agentType).buildItems(from: rawEvent)
    }
}
