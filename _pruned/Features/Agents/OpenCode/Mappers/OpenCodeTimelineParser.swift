import Foundation

struct OpenCodeTimelineParser: AgentTimelineParser {
    let agentType: AgentChannelType = .openCode

    func buildItems(from rawEvent: AgentRawEventEnvelope) -> [AgentTimelineItem] {
        DefaultRawTimelineParser(agentType: agentType).buildItems(from: rawEvent)
    }
}
