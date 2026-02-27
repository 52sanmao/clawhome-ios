import Foundation

struct GeminiTimelineParser: AgentTimelineParser {
    let agentType: AgentChannelType = .geminiCLI

    func buildItems(from rawEvent: AgentRawEventEnvelope) -> [AgentTimelineItem] {
        DefaultRawTimelineParser(agentType: agentType).buildItems(from: rawEvent)
    }
}
