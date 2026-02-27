//
//  SpaceViewModel.swift
//  contextgo
//
//  Space 状态管理 - 使用 Core API
//

import Foundation
import SwiftUI

@MainActor
class SpaceViewModel: ObservableObject {
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var currentSpace: Space?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?

    private let spaceService = SpaceService.shared

    var defaultSpace: Space? {
        spaces.first
    }

    // MARK: - Load Spaces

    func loadSpaces() async {
        isLoading = true
        error = nil
        do {
            spaces = try await spaceService.fetchSpaces()
            if currentSpace == nil {
                currentSpace = defaultSpace
            }
            print("[Space] Loaded \(spaces.count) spaces")
        } catch {
            self.error = "加载 Space 失败: \(error.localizedDescription)"
            print("[Space] Error: \(error)")
        }
        isLoading = false
    }

    // MARK: - Select Space

    func selectSpace(_ space: Space) {
        currentSpace = space
    }

    // MARK: - Create Space

    func createSpace(displayName: String, name: String? = nil, description: String? = nil) async -> Bool {
        isLoading = true
        error = nil
        do {
            let newSpace = try await spaceService.createSpace(displayName: displayName, name: name, description: description)
            print("[Space] Created: \(newSpace.displayName)")
            await loadSpaces()
            return true
        } catch {
            self.error = "创建 Space 失败: \(error.localizedDescription)"
            print("[Space] Create error: \(error)")
            isLoading = false
            return false
        }
    }

    // MARK: - Delete Space

    func deleteSpace(spaceId: String) async -> Bool {
        isLoading = true
        error = nil
        do {
            try await spaceService.deleteSpace(spaceId: spaceId)
            if currentSpace?.id == spaceId { currentSpace = nil }
            await loadSpaces()
            return true
        } catch {
            self.error = "删除 Space 失败: \(error.localizedDescription)"
            print("[Space] Delete error: \(error)")
            isLoading = false
            return false
        }
    }

    func clearError() {
        error = nil
    }
}
