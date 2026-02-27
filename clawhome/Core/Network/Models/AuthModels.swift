//
//  AuthModels.swift
//  contextgo
//
//  认证相关数据模型 — 对齐 contextgo-core API
//

import Foundation

// MARK: - User

struct User: Codable, Identifiable {
    let id: String
    let email: String
    let displayName: String
    let createdAt: String?
    let lastLoginAt: String?
}

// MARK: - Auth API Responses

struct AuthResponse: Decodable {
    let success: Bool
    let token: String?
    let user: User?
    let error: String?
}

struct MeResponse: Decodable {
    let success: Bool
    let user: User?
}
