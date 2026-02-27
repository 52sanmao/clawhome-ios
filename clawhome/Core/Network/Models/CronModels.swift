//
//  CronModels.swift
//  contextgo
//
//  Cron 定时任务相关数据模型
//

import Foundation

// MARK: - Cron Job

struct CronJob: Codable, Identifiable {
    let id: String
    let agentId: String
    let name: String
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let schedule: CronSchedule
    let sessionTarget: String
    let wakeMode: String
    let payload: CronPayload
    let state: CronState

    var createdAt: Date {
        Date(timeIntervalSince1970: Double(createdAtMs) / 1000)
    }

    var updatedAt: Date {
        Date(timeIntervalSince1970: Double(updatedAtMs) / 1000)
    }
}

struct CronSchedule: Codable {
    let kind: String  // "cron"
    let expr: String  // "0 0 * * *"
    let tz: String    // "UTC"
}

struct CronPayload: Codable {
    let kind: String  // "systemEvent"
    let text: String?
}

struct CronState: Codable {
    // Empty object in current API response
}

// MARK: - Cron Event (WebSocket)

/// Cron job execution event received from Gateway
struct CronEvent: Codable {
    let type: String  // "event"
    let event: String  // "cron"
    let payload: CronEventPayload
    let seq: Int?

    struct CronEventPayload: Codable {
        let jobId: String
        let action: String  // "started" or "finished"
        let runAtMs: Int64

        // Only present when action == "finished"
        let status: String?  // "ok" or "error"
        let summary: String?
        let durationMs: Int?

        var runAt: Date {
            Date(timeIntervalSince1970: Double(runAtMs) / 1000)
        }
    }
}

// MARK: - Request/Write Models (may differ from response models)

/// Action model for cron job creation/update requests
/// Note: This is different from CronPayload which is used in responses
struct CronAction: Codable {
    let type: String
    let prompt: String
    let agentId: String?

    enum CodingKeys: String, CodingKey {
        case type, prompt
        case agentId = "agent_id"
    }
}

// MARK: - Cron Status

struct CronStatus: Codable {
    let enabled: Bool
    let storePath: String?
    let jobs: Int  // Total number of jobs
    let nextWakeAtMs: Int64?  // Next wake time in milliseconds

    enum CodingKeys: String, CodingKey {
        case enabled
        case storePath
        case jobs
        case nextWakeAtMs
    }

    // Computed properties for backward compatibility
    var totalJobs: Int { jobs }
    var activeJobs: Int { enabled ? jobs : 0 }

    var nextRunDate: Date? {
        guard let nextWakeAtMs = nextWakeAtMs else { return nil }
        return Date(timeIntervalSince1970: Double(nextWakeAtMs) / 1000)
    }

    var lastHeartbeatDate: Date? {
        // Not provided by API
        return nil
    }
}

// MARK: - Cron Run Entry

struct CronRunEntry: Codable, Identifiable {
    let ts: Int64          // Timestamp in milliseconds
    let jobId: String      // Job ID
    let action: String     // "finished"
    let status: String     // "ok" or "error"
    let summary: String?   // Result summary
    let runAtMs: Int64     // Run time in milliseconds
    let durationMs: Int?   // Duration in milliseconds

    var id: String { "\(jobId)-\(ts)" }  // Generate unique ID

    var timestamp: Date {
        Date(timeIntervalSince1970: Double(ts) / 1000)
    }

    var runAt: Date {
        Date(timeIntervalSince1970: Double(runAtMs) / 1000)
    }

    var duration: TimeInterval? {
        guard let durationMs = durationMs else { return nil }
        return Double(durationMs) / 1000
    }

    var isSuccess: Bool {
        status == "ok"
    }
}

// MARK: - RPC Request Models

struct CronListRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String = "cron.list"
    let params: CronListParams

    struct CronListParams: Encodable {
        let includeDisabled: Bool
        // No CodingKeys - backend expects camelCase
    }
}

struct CronStatusRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String = "cron.status"
    let params: EmptyParams

    struct EmptyParams: Encodable {}
}

struct CronRunsRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String = "cron.runs"
    let params: CronRunsParams

    struct CronRunsParams: Encodable {
        let id: String
        let limit: Int?
    }
}

struct CronAddRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String = "cron.add"
    let params: CronAddParams

    struct CronAddParams: Encodable {
        let id: String
        let schedule: String
        let action: CronAction
        let enabled: Bool
    }
}

struct CronUpdateRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String = "cron.update"
    let params: CronUpdateParams

    struct CronUpdateParams: Encodable {
        let id: String
        let patch: CronJobPatch
    }
}

struct CronJobPatch: Encodable {
    let schedule: String?
    let enabled: Bool?
    let action: CronAction?
}

struct CronRemoveRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String = "cron.remove"
    let params: CronRemoveParams

    struct CronRemoveParams: Encodable {
        let id: String
    }
}

struct CronRunRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String = "cron.run"
    let params: CronRunParams

    struct CronRunParams: Encodable {
        let id: String
        let mode: String  // "due" or "force"
    }
}

// MARK: - RPC Response Models

struct CronListResponse: Decodable {
    let type: String
    let id: String
    let ok: Bool
    let payload: CronListPayload?

    struct CronListPayload: Decodable {
        let jobs: [CronJob]
    }
}

struct CronStatusResponse: Decodable {
    let type: String
    let id: String
    let ok: Bool
    let payload: CronStatus?
}

struct CronRunsResponse: Decodable {
    let type: String
    let id: String
    let ok: Bool
    let payload: CronRunsPayload?

    struct CronRunsPayload: Decodable {
        let entries: [CronRunEntry]
    }
}

struct CronGenericResponse: Decodable {
    let type: String
    let id: String
    let ok: Bool
    let payload: CronGenericPayload?

    struct CronGenericPayload: Decodable {
        let removed: Bool?
    }
}
