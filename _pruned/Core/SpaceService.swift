//
//  SpaceService.swift
//  contextgo
//
//  Space API 服务层 - 使用 Core API
//

import Foundation

@MainActor
class SpaceService: ObservableObject {
    static let shared = SpaceService()
    private let client = CoreAPIClient.shared
    private init() {}

    func fetchSpaces() async throws -> [Space] {
        return try await client.listSpaces()
    }

    func createSpace(displayName: String, name: String? = nil, description: String? = nil) async throws -> Space {
        return try await client.createSpace(displayName: displayName, name: name, description: description)
    }

    func deleteSpace(spaceId: String) async throws {
        try await client.deleteSpace(spaceId: spaceId)
    }
}
