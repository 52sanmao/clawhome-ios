//
//  OpenClawMessage.swift
//  contextgo
//
//  IronClaw-compatible WebSocket protocol messages
//

import Foundation

// MARK: - Request/Response Types

enum MessageType: String, Codable {
    case req        // Request
    case res        // Response
    case event      // Server-pushed event
}

// MARK: - Connect Messages

struct ConnectRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "connect"
    let params: ConnectParams

    struct ConnectParams: Codable {
        let minProtocol: Int
        let maxProtocol: Int
        let client: ClientInfo
        let role: String?  // "operator" or "node"
        let scopes: [String]?  // For operator role
        let caps: [String]  // Node capabilities
        let commands: [String]?  // Node commands
        let permissions: [String: Bool]?  // Node permissions
        let locale: String?
        let auth: AuthInfo?

        struct ClientInfo: Codable {
            let id: String
            let displayName: String?
            let version: String
            let platform: String
            let mode: String
            let instanceId: String?
        }

        struct AuthInfo: Codable {
            let token: String?
            let signature: String?  // ✅ For challenge-response auth
            let nonce: String?      // ✅ For challenge-response auth
        }
    }
}

// Hello-OK Response (initial handshake) - matches Gateway protocol schema
struct HelloResponse: Codable {
    let type: String  // "hello-ok"
    let `protocol`: Int
    let server: ServerInfo
    let features: Features
    let snapshot: Snapshot
    let canvasHostUrl: String?
    let auth: AuthInfo?
    let policy: Policy

    struct ServerInfo: Codable {
        let version: String
        let commit: String?
        let host: String?
        let connId: String
    }

    struct Features: Codable {
        let methods: [String]
        let events: [String]
    }

    struct Snapshot: Codable {
        let presence: [PresenceEntry]  // Array, not single object!
        let health: AnyCodable?        // Any type
        let stateVersion: StateVersion
        let uptimeMs: Int
        let configPath: String?
        let stateDir: String?
        let sessionDefaults: SessionDefaults?

        struct PresenceEntry: Codable {
            let host: String?
            let ip: String?
            let version: String?
            let platform: String?
            let deviceFamily: String?
            let modelIdentifier: String?
            let mode: String?
            let lastInputSeconds: Int?
            let reason: String?
            let tags: [String]?
            let text: String?
            let ts: Int
            let deviceId: String?
            let roles: [String]?
            let scopes: [String]?
            let instanceId: String?
        }

        struct StateVersion: Codable {
            let presence: Int
            let health: Int
        }

        struct SessionDefaults: Codable {
            let defaultAgentId: String
            let mainKey: String
            let mainSessionKey: String
            let scope: String?
        }
    }

    struct AuthInfo: Codable {
        let deviceToken: String
        let role: String
        let scopes: [String]
        let issuedAtMs: Int?
    }

    struct Policy: Codable {
        let maxPayload: Int
        let maxBufferedBytes: Int
        let tickIntervalMs: Int
    }
}

// Standard Connect Response (with payload)
struct ConnectResponse: Codable {
    let type: String
    let id: String?
    let ok: Bool?
    let payload: HelloPayload?
    let error: ErrorPayload?

    struct HelloPayload: Codable {
        let presence: PresenceInfo?
        let health: HealthInfo?

        struct PresenceInfo: Codable {
            let online: Bool
            let model: String?
        }

        struct HealthInfo: Codable {
            let status: String
            let uptime: Double?
        }
    }

    struct ErrorPayload: Codable {
        let message: String
        let code: String?
    }
}

// MARK: - Agent Messages (Chat)

// ✅ NEW: OpenClaw Attachment Protocol
struct OpenClawAttachment: Codable {
    let type: String        // "image", "file", "video", "audio"
    let mimeType: String
    let fileName: String
    let content: String     // Base64 data URL: "data:image/jpeg;base64,..."
}

struct AgentRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "agent"
    let params: AgentParams

    struct AgentParams: Codable {
        let message: String
        let idempotencyKey: String
        let thinking: String?
        let sessionKey: String?
        let agentId: String?
        let sessionId: String?
        let lane: String?
        let deliver: Bool?
        let timeout: Int?
        let extraSystemPrompt: String?
        let attachments: [OpenClawAttachment]?  // ✅ NEW: Support attachments
    }
}

struct AgentResponse: Codable {
    let type: String
    let id: String
    let ok: Bool
    let payload: AgentPayload?
    let error: ErrorPayload?

    struct AgentPayload: Codable {
        let runId: String?
        let status: String?
        let summary: String?
        let text: String?
    }

    struct ErrorPayload: Codable {
        let message: String
        let code: String?
    }
}

// MARK: - Chat Abort Request/Response

struct AbortRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "chat.abort"
    let params: AbortParams

    struct AbortParams: Codable {
        let sessionKey: String
        let runId: String?  // Optional: if not provided, abort all runs in session
    }
}

struct AbortResponse: Codable {
    let type: String
    let id: String
    let ok: Bool
    let payload: AbortPayload?
    let error: ErrorPayload?

    struct AbortPayload: Codable {
        let aborted: Int  // Number of runs aborted
        let runIds: [String]?  // List of aborted run IDs
    }

    struct ErrorPayload: Codable {
        let message: String
        let code: String?
    }
}

// MARK: - Chat Event
struct ChatEvent: Decodable {
    let type: String = "event"
    let event: String = "chat"
    let payload: ChatEventPayload
    let seq: Int?

    struct ChatEventPayload: Decodable {
        let runId: String
        let sessionKey: String
        let seq: Int
        let state: String
        let message: Message?
        let error: ErrorInfo?
        let errorMessage: String?
        let stopReason: String?

        struct Message: Decodable {
            let role: String
            let content: [Content]
            let timestamp: Int

            struct Content: Decodable {
                let type: String
                let text: String?

                enum CodingKeys: String, CodingKey {
                    case type, text, content, value, thinking
                }

                init(type: String, text: String?) {
                    self.type = type
                    self.text = text
                }

                init(from decoder: Decoder) throws {
                    if let single = try? decoder.singleValueContainer(),
                       let stringValue = try? single.decode(String.self) {
                        self.type = "text"
                        self.text = stringValue
                        return
                    }

                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.type = (try? container.decode(String.self, forKey: .type)) ?? "text"
                    if let value = try container.decodeIfPresent(String.self, forKey: .text) {
                        self.text = value
                    } else if let value = try container.decodeIfPresent(String.self, forKey: .thinking) {
                        self.text = value
                    } else if let value = try container.decodeIfPresent(String.self, forKey: .content) {
                        self.text = value
                    } else if let value = try container.decodeIfPresent(String.self, forKey: .value) {
                        self.text = value
                    } else {
                        self.text = nil
                    }
                }

            }

            enum CodingKeys: String, CodingKey {
                case role, content, timestamp
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                role = try container.decode(String.self, forKey: .role)
                timestamp = (try? container.decode(Int.self, forKey: .timestamp))
                    ?? Int(Date().timeIntervalSince1970 * 1000)

                if let arrayContent = try? container.decode([Content].self, forKey: .content) {
                    content = arrayContent
                } else if let objectContent = try? container.decode(Content.self, forKey: .content) {
                    content = [objectContent]
                } else if let stringContent = try? container.decode(String.self, forKey: .content) {
                    content = [Content(type: "text", text: stringContent)]
                } else {
                    content = []
                }
            }
        }

        struct ErrorInfo: Decodable {
            let message: String
        }
    }
}

// MARK: - Agent Event (Streaming) - matches Gateway protocol schema

struct AgentEvent: Codable {
    let type: String = "event"
    let event: String = "agent"
    let payload: AgentEventPayload
    let seq: Int?
    let stateVersion: StateVersion?

    struct AgentEventPayload: Codable {
        let runId: String
        let seq: Int
        let stream: String
        let ts: Int
        let data: [String: AnyCodable]
        let sessionKey: String?  // Added: contains session key to identify channel
    }

    struct StateVersion: Codable {
        let v: Int
    }
}

// MARK: - Connect Challenge Event

struct ConnectChallengeEvent: Codable {
    let type: String = "event"
    let event: String = "connect.challenge"
    let payload: ChallengePayload

    struct ChallengePayload: Codable {
        let nonce: String
        let ts: Int
    }
}

// MARK: - Challenge Response (Authentication)

struct ChallengeResponse: Codable {
    let type: String = "req"
    let id: String
    let method: String = "auth"
    let params: AuthParams

    struct AuthParams: Codable {
        let signature: String
        let nonce: String
    }
}

// MARK: - Health Messages

struct HealthRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "health"
}

struct HealthResponse: Codable {
    let type: String
    let id: String
    let ok: Bool
    let payload: HealthPayload?

    struct HealthPayload: Codable {
        let status: String
        let uptime: Double?
        let version: String?
    }
}

// MARK: - Health Event (periodic heartbeat with channel status)

struct HealthEvent: Codable {
    let type: String = "event"
    let event: String = "health"
    let payload: HealthEventPayload
    let seq: Int?
    let stateVersion: StateVersion?

    struct HealthEventPayload: Codable {
        let ok: Bool
        let ts: Int
        let durationMs: Int?
        let channels: AnyCodable?  // Can be array or object
        let channelOrder: [String]?
        let channelLabels: [String: String]?
        let heartbeatSeconds: Int?
        let defaultAgentId: String?
        let agents: [AgentInfo]?  // Array of agent info
        let sessions: AnyCodable?  // Session info (flexible structure)

        struct AgentInfo: Codable {
            let agentId: String
            let isDefault: Bool?
            let heartbeat: HeartbeatInfo?
            let sessions: SessionInfo?

            struct HeartbeatInfo: Codable {
                let enabled: Bool?
                let every: String?
                let everyMs: Int?
                let prompt: String?
                let target: String?
                let ackMaxChars: Int?
            }

            struct SessionInfo: Codable {
                let path: String?
                let count: Int?
                let recent: [RecentSession]?

                struct RecentSession: Codable {
                    let key: String
                    let updatedAt: Int?
                    let age: Int?
                }
            }
        }
    }

    struct StateVersion: Codable {
        let presence: Int
        let health: Int
    }
}

// MARK: - Generic Message Wrapper

enum OpenClawMessage {
    case connectRequest(ConnectRequest)
    case helloResponse(HelloResponse)
    case connectResponse(ConnectResponse)
    case connectChallengeEvent(ConnectChallengeEvent)
    case challengeResponse(ChallengeResponse)
    case agentRequest(AgentRequest)
    case agentResponse(AgentResponse)
    case agentEvent(AgentEvent)
    case chatEvent(ChatEvent)
    case healthRequest(HealthRequest)
    case healthResponse(HealthResponse)
    case healthEvent(HealthEvent)
    case cronEvent(CronEvent)  // ✅ NEW
    case unknown

    init(from data: Data) {
        // Print raw message for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            print("[OpenClaw] Parsing message: \(jsonString.prefix(200))...")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("[OpenClaw] ❌ Failed to parse message type")
            self = .unknown
            return
        }

        print("[OpenClaw] Message type: \(type)")

        switch type {
        case "req":
            // Outgoing request (we don't usually parse our own requests)
            self = .unknown

        case "hello-ok":
            // Parse hello-ok handshake response
            print("[OpenClaw] Attempting to decode hello-ok...")
            if let response = try? JSONDecoder().decode(HelloResponse.self, from: data) {
                print("[OpenClaw] ✅ Successfully decoded hello-ok")
                self = .helloResponse(response)
            } else {
                print("[OpenClaw] ❌ Failed to decode hello-ok")
                self = .unknown
            }

        case "res":
            // Check if this is a hello-ok response wrapped in a res frame
            if let payload = json["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String,
               payloadType == "hello-ok" {
                // This is a hello-ok wrapped in a res response
                print("[OpenClaw] Attempting to decode hello-ok from res payload...")
                if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                   let response = try? JSONDecoder().decode(HelloResponse.self, from: payloadData) {
                    print("[OpenClaw] ✅ Successfully decoded hello-ok from payload")
                    self = .helloResponse(response)
                    return
                } else {
                    print("[OpenClaw] ❌ Failed to decode hello-ok from payload")
                }
            }

            // Parse response based on id pattern or payload structure
            if let payload = json["payload"] as? [String: Any],
               payload["presence"] != nil || payload["health"] != nil {
                if let response = try? JSONDecoder().decode(ConnectResponse.self, from: data) {
                    self = .connectResponse(response)
                } else {
                    self = .unknown
                }
            } else if let payload = json["payload"] as? [String: Any],
                      payload["runId"] != nil || payload["text"] != nil {
                if let response = try? JSONDecoder().decode(AgentResponse.self, from: data) {
                    self = .agentResponse(response)
                } else {
                    self = .unknown
                }
            } else if let response = try? JSONDecoder().decode(HealthResponse.self, from: data) {
                self = .healthResponse(response)
            } else {
                self = .unknown
            }

        case "event":
            // Parse event
            if let event = json["event"] as? String {
                switch event {
                case "connect.challenge":
                    if let challengeEvent = try? JSONDecoder().decode(ConnectChallengeEvent.self, from: data) {
                        self = .connectChallengeEvent(challengeEvent)
                    } else {
                        self = .unknown
                    }
                case "agent":
                    if let agentEvent = try? JSONDecoder().decode(AgentEvent.self, from: data) {
                        self = .agentEvent(agentEvent)
                    } else {
                        self = .unknown
                    }
                case "chat":
                    if let chatEvent = try? JSONDecoder().decode(ChatEvent.self, from: data) {
                        self = .chatEvent(chatEvent)
                    } else {
                        self = .unknown
                    }
                case "health":
                    if let healthEvent = try? JSONDecoder().decode(HealthEvent.self, from: data) {
                        self = .healthEvent(healthEvent)
                    } else {
                        self = .unknown
                    }
                case "tick":
                    // ✅ Heartbeat event - silently ignore (no action needed)
                    self = .unknown
                case "cron":
                    // ✅ Cron job event - parse and notify
                    if let cronEvent = try? JSONDecoder().decode(CronEvent.self, from: data) {
                        self = .cronEvent(cronEvent)
                    } else {
                        self = .unknown
                    }
                default:
                    print("[OpenClaw] ⚠️ Unknown event type: \(event)")
                    self = .unknown
                }
            } else {
                self = .unknown
            }

        default:
            self = .unknown
        }
    }
}

// MARK: - Chat History Messages

struct ChatHistoryRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "chat.history"
    let params: HistoryParams

    struct HistoryParams: Codable {
        let sessionKey: String
        let limit: Int?
    }
}

struct ChatHistoryResponse: Decodable {
    let type: String
    let id: String
    let ok: Bool
    let payload: HistoryPayload?
    let result: HistoryPayload?
    let error: ErrorPayload?

    var historyPayload: HistoryPayload? {
        payload ?? result
    }

    struct HistoryPayload: Decodable {
        let sessionKey: String
        let sessionId: String?
        let thinkingLevel: String?
        let messages: [HistoryMessage]
    }

    struct HistoryMessage: Decodable {
        let id: String
        let timestamp: Int
        let role: String
        let content: [MessageContent]
        let toolUse: [ToolUse]?
        let toolResult: [ToolResult]?

        enum CodingKeys: String, CodingKey {
            case id, timestamp, role, content, toolUse, toolResult
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
            if let intTimestamp = try? container.decode(Int.self, forKey: .timestamp) {
                timestamp = intTimestamp
            } else if let doubleTimestamp = try? container.decode(Double.self, forKey: .timestamp) {
                timestamp = Int(doubleTimestamp)
            } else {
                timestamp = Int(Date().timeIntervalSince1970 * 1000)
            }
            role = try container.decode(String.self, forKey: .role)

            if let arrayContent = try? container.decode([MessageContent].self, forKey: .content) {
                content = arrayContent
            } else if let objectContent = try? container.decode(MessageContent.self, forKey: .content) {
                content = [objectContent]
            } else if let stringContent = try? container.decode(String.self, forKey: .content) {
                content = [MessageContent(type: "text", text: stringContent)]
            } else {
                content = []
            }

            toolUse = try container.decodeIfPresent([ToolUse].self, forKey: .toolUse)
            toolResult = try container.decodeIfPresent([ToolResult].self, forKey: .toolResult)
        }

        struct MessageContent: Decodable {
            let type: String
            let text: String?

            enum CodingKeys: String, CodingKey {
                case type, text, content, value, thinking
            }

            init(type: String, text: String?) {
                self.type = type
                self.text = text
            }

            init(from decoder: Decoder) throws {
                if let singleValue = try? decoder.singleValueContainer(),
                   let stringValue = try? singleValue.decode(String.self) {
                    type = "text"
                    text = stringValue
                    return
                }

                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = (try? container.decode(String.self, forKey: .type)) ?? "text"

                if let value = try container.decodeIfPresent(String.self, forKey: .text) {
                    text = value
                } else if let value = try container.decodeIfPresent(String.self, forKey: .thinking) {
                    text = value
                } else if let value = try container.decodeIfPresent(String.self, forKey: .content) {
                    text = value
                } else if let value = try container.decodeIfPresent(String.self, forKey: .value) {
                    text = value
                } else {
                    text = nil
                }
            }
        }

        struct ToolUse: Decodable {
            let id: String
            let type: String
            let name: String
            let input: AnyCodable?
        }

        struct ToolResult: Decodable {
            let tool_use_id: String
            let type: String
            let content: String?
            let is_error: Bool?
        }
    }

    struct ErrorPayload: Decodable {
        let message: String
        let code: String?
    }
}

// MARK: - Sessions List Messages (JSON-RPC 2.0)

struct SessionsListRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "sessions.list"
    let params: SessionsListParams

    struct SessionsListParams: Codable {
        let limit: Int?
        let activeMinutes: Int?
        let includePreview: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case type, id, method, params
    }
}

struct SessionsListResponse: Codable {
    let type: String?
    let ok: Bool?
    let id: String
    let result: SessionsResult?
    let payload: SessionsResult?
    let error: ErrorPayload?

    var sessions: [RemoteSessionInfo]? {
        result?.sessions ?? payload?.sessions
    }

    struct ErrorPayload: Codable {
        let message: String
        let code: String?
    }

    struct SessionsResult: Codable {
        let ts: Int?
        let count: Int?
        let sessions: [RemoteSessionInfo]
    }

    struct RemoteSessionInfo: Codable {
        let key: String           // Session Key (主要标识符)
        let kind: String?         // direct | group | global | unknown
        let displayName: String?
        let updatedAt: Int?
        let sessionId: String?    // 内部 UUID
        let channel: String?
        let totalTokens: Int?
    }
}

// MARK: - Sessions Patch Messages (JSON-RPC 2.0)

struct SessionsPatchRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "sessions.patch"
    let params: SessionsPatchParams

    struct SessionsPatchParams: Codable {
        let key: String
        let thinkingLevel: String?
        let model: String?
    }

    enum CodingKeys: String, CodingKey {
        case type, id, method, params
    }
}

struct SessionsPatchResponse: Codable {
    let id: String
    let result: PatchResult?

    struct PatchResult: Codable {
        let ok: Bool?
        let entry: SessionEntry?

        struct SessionEntry: Codable {
            let sessionId: String?
            let thinkingLevel: String?
            let updatedAt: Int?
            let model: String?
        }
    }
}
