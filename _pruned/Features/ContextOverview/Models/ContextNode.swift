//
//  ContextNode.swift
//  contextgo
//
//  Context node model representing devices and data sources
//

import SwiftUI

struct ContextNode: Identifiable {
    let id = UUID()
    let icon: String          // SF Symbol name
    let name: String          // Display name
    let color: Color          // Theme color
    let angle: Double         // Initial angle (degrees, 0-360)
    var isActive: Bool        // Whether the node is active
    var lastSyncTime: Date?   // Last sync timestamp
    var dataSize: Int64?      // Data size in bytes

    // Computed property: formatted data size
    var dataSizeFormatted: String? {
        guard let size = dataSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    // Computed property: time since last sync
    var timeSinceSync: String? {
        guard let syncTime = lastSyncTime else { return nil }
        let interval = Date().timeIntervalSince(syncTime)

        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) 分钟前"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) 小时前"
        } else {
            let days = Int(interval / 86400)
            return "\(days) 天前"
        }
    }
}

// MARK: - Sample Data
extension ContextNode {
    static let sampleNodes: [ContextNode] = [
        ContextNode(
            icon: "airpodspro",
            name: "耳机",
            color: .blue,
            angle: 0,
            isActive: true,
            lastSyncTime: Date().addingTimeInterval(-120),
            dataSize: 2_500_000
        ),
        ContextNode(
            icon: "vision.pro",
            name: "眼镜",
            color: .purple,
            angle: 45,
            isActive: false,
            lastSyncTime: Date().addingTimeInterval(-86400),
            dataSize: nil
        ),
        ContextNode(
            icon: "iphone",
            name: "手机",
            color: .gray,
            angle: 90,
            isActive: true,
            lastSyncTime: Date().addingTimeInterval(-30),
            dataSize: 15_000_000
        ),
        ContextNode(
            icon: "laptopcomputer",
            name: "电脑",
            color: .secondary,
            angle: 135,
            isActive: true,
            lastSyncTime: Date().addingTimeInterval(-60),
            dataSize: 45_000_000
        ),
        ContextNode(
            icon: "applewatch",
            name: "手表",
            color: .red,
            angle: 180,
            isActive: false,
            lastSyncTime: Date().addingTimeInterval(-172800),
            dataSize: nil
        ),
        ContextNode(
            icon: "folder.fill",
            name: "文件",
            color: .yellow,
            angle: 225,
            isActive: true,
            lastSyncTime: Date().addingTimeInterval(-180),
            dataSize: 128_000_000
        ),
        ContextNode(
            icon: "waveform",
            name: "语音",
            color: .orange,
            angle: 270,
            isActive: true,
            lastSyncTime: Date().addingTimeInterval(-90),
            dataSize: 8_500_000
        ),
        ContextNode(
            icon: "photo.stack",
            name: "照片",
            color: .pink,
            angle: 315,
            isActive: false,
            lastSyncTime: Date().addingTimeInterval(-259200),
            dataSize: nil
        )
    ]
}
