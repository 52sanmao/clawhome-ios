//
//  UsageCostModels.swift
//  contextgo
//
//  Token 使用统计和成本数据模型
//

import Foundation

// MARK: - Request

struct UsageCostRequest: Encodable {
    let type: String = "req"
    let id: String
    let method: String = "usage.cost"
    let params: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case type, id, method, params
    }
}

struct SessionUsageRequest: Encodable {
    struct Params: Encodable {
        let key: String
        let limit: Int
    }

    let type: String = "req"
    let id: String
    let method: String = "sessions.usage"
    let params: Params

    init(id: String, sessionKey: String, limit: Int = 1) {
        self.id = id
        self.params = Params(key: sessionKey, limit: limit)
    }
}

// MARK: - Response

struct UsageCostResponse: Decodable {
    let ok: Bool
    let payload: UsageCostPayload?
}

struct SessionUsageResponse: Decodable {
    struct SessionEntry: Decodable {
        let key: String
        let usage: SessionUsageSummary?
    }

    struct SessionUsageSummary: Decodable {
        struct DailyBreakdownEntry: Decodable {
            let date: String
            let tokens: Int
            let cost: Double
        }

        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let totalTokens: Int
        let totalCost: Double
        let inputCost: Double
        let outputCost: Double
        let cacheReadCost: Double
        let cacheWriteCost: Double
        let missingCostEntries: Int
        let dailyBreakdown: [DailyBreakdownEntry]?
    }

    struct Payload: Decodable {
        let updatedAt: Int64
        let sessions: [SessionEntry]
        let totals: UsageTotals
    }

    let ok: Bool
    let payload: Payload?
}

struct UsageCostPayload: Decodable {
    let updatedAt: Int64
    let days: Int
    let daily: [DailyUsage]
    let totals: UsageTotals
}

struct DailyUsage: Decodable, Identifiable {
    let date: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let totalTokens: Int
    let totalCost: Double
    let inputCost: Double?  // Optional - not always present
    let outputCost: Double?  // Optional - not always present
    let cacheReadCost: Double?  // Optional - not always present
    let cacheWriteCost: Double?  // Optional - not always present
    let missingCostEntries: Int

    var id: String { date }
}

struct UsageTotals: Decodable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let totalTokens: Int
    let totalCost: Double
    let inputCost: Double?  // Optional - not always present
    let outputCost: Double?  // Optional - not always present
    let cacheReadCost: Double?  // Optional - not always present
    let cacheWriteCost: Double?  // Optional - not always present
    let missingCostEntries: Int
}

extension SessionUsageResponse.SessionUsageSummary {
    func toUsageCostPayload(updatedAt: Int64) -> UsageCostPayload {
        let dailyEntries = (dailyBreakdown ?? []).map {
            DailyUsage(
                date: $0.date,
                input: $0.tokens,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                totalTokens: $0.tokens,
                totalCost: $0.cost,
                inputCost: nil,
                outputCost: nil,
                cacheReadCost: nil,
                cacheWriteCost: nil,
                missingCostEntries: 0
            )
        }

        let totals = UsageTotals(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            totalTokens: totalTokens,
            totalCost: totalCost,
            inputCost: inputCost,
            outputCost: outputCost,
            cacheReadCost: cacheReadCost,
            cacheWriteCost: cacheWriteCost,
            missingCostEntries: missingCostEntries
        )

        return UsageCostPayload(
            updatedAt: updatedAt,
            days: dailyEntries.count,
            daily: dailyEntries,
            totals: totals
        )
    }
}
