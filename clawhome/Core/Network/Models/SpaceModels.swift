//
//  SpaceModels.swift
//  contextgo
//
//  Space、Task、Skill 数据模型 — 对齐 contextgo-core API
//

import Foundation

// MARK: - Space

struct Space: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let displayName: String
    let description: String?
    let createdAt: String
    let lastActiveAt: String?
    let contextCount: Int
    let taskCount: Int
    let storageUsed: Int
}

// MARK: - SpaceTask (避免与 Swift.Task 冲突)

struct SpaceTask: Codable, Identifiable {
    let id: String
    let title: String
    let status: String
    let createdAt: String
    let taskUri: String?
}

// MARK: - SpaceSkill (避免与 OpenClaw Skill 冲突)

struct SpaceSkill: Codable, Identifiable {
    let id: String
    let name: String
    let type: String
    let skillUri: String?
}

// MARK: - API Responses

struct SpaceListResponse: Decodable {
    let success: Bool
    let data: [Space]
}

struct SpaceResponse: Decodable {
    let success: Bool
    let data: Space?
    let error: String?
}
