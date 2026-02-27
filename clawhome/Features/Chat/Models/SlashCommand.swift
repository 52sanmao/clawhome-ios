//
//  SlashCommand.swift
//  contextgo
//
//  Slash command system for quick actions
//

import SwiftUI

struct SlashCommand: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String
    let category: CommandCategory
    let action: CommandAction

    enum CommandCategory: String {
        case session = "会话管理"
        case status = "状态与信息"
        case model = "模型与配置"
        case tools = "工具与技能"
        case channel = "多通道"
    }

    enum CommandAction {
        case local(LocalAction)      // 本地执行的命令
        case sendToAI(String)         // 发送给 AI 的命令

        enum LocalAction {
            case clearSession
        }
    }
}

extension SlashCommand {
    // 本地命令（在客户端执行）
    static let localCommands: [SlashCommand] = [
        SlashCommand(
            name: "clear",
            description: "清空当前会话",
            icon: "trash.fill",
            category: .session,
            action: .local(.clearSession)
        )
    ]

    // AI 命令（发送给服务器处理）
    static let aiCommands: [SlashCommand] = [
        // 会话管理
        SlashCommand(
            name: "new",
            description: "新建会话",
            icon: "plus.circle.fill",
            category: .session,
            action: .sendToAI("/new")
        ),
        SlashCommand(
            name: "reset",
            description: "重置当前会话",
            icon: "arrow.counterclockwise",
            category: .session,
            action: .sendToAI("/reset")
        ),
        SlashCommand(
            name: "stop",
            description: "停止当前运行",
            icon: "stop.circle",
            category: .session,
            action: .sendToAI("/stop")
        ),
        SlashCommand(
            name: "compact",
            description: "压缩会话上下文",
            icon: "arrow.down.circle",
            category: .session,
            action: .sendToAI("/compact")
        ),

        // 状态与信息
        SlashCommand(
            name: "help",
            description: "显示可用命令",
            icon: "questionmark.circle",
            category: .status,
            action: .sendToAI("/help")
        ),
        SlashCommand(
            name: "commands",
            description: "列出所有斜杠命令",
            icon: "list.bullet",
            category: .status,
            action: .sendToAI("/commands")
        ),
        SlashCommand(
            name: "status",
            description: "显示当前状态",
            icon: "info.circle",
            category: .status,
            action: .sendToAI("/status")
        ),
        SlashCommand(
            name: "whoami",
            description: "显示发送者ID",
            icon: "person.circle",
            category: .status,
            action: .sendToAI("/whoami")
        ),
        SlashCommand(
            name: "context",
            description: "解释上下文使用",
            icon: "doc.text",
            category: .status,
            action: .sendToAI("/context")
        ),

        // 模型与配置
        SlashCommand(
            name: "model",
            description: "查看或设置模型",
            icon: "cpu",
            category: .model,
            action: .sendToAI("/model")
        ),
        SlashCommand(
            name: "models",
            description: "列出模型提供者",
            icon: "list.bullet.rectangle",
            category: .model,
            action: .sendToAI("/models")
        ),
        SlashCommand(
            name: "think",
            description: "设置思考级别",
            icon: "brain",
            category: .model,
            action: .sendToAI("/think")
        ),
        SlashCommand(
            name: "verbose",
            description: "切换详细模式",
            icon: "text.bubble",
            category: .model,
            action: .sendToAI("/verbose")
        ),

        // 工具与技能
        SlashCommand(
            name: "skill",
            description: "运行指定技能",
            icon: "wrench.and.screwdriver",
            category: .tools,
            action: .sendToAI("/skill")
        ),
        SlashCommand(
            name: "bash",
            description: "运行shell命令",
            icon: "terminal",
            category: .tools,
            action: .sendToAI("/bash")
        ),

        // 多通道
        SlashCommand(
            name: "dock-telegram",
            description: "切换到Telegram",
            icon: "paperplane",
            category: .channel,
            action: .sendToAI("/dock-telegram")
        ),
        SlashCommand(
            name: "dock-discord",
            description: "切换到Discord",
            icon: "bubble.left.and.bubble.right",
            category: .channel,
            action: .sendToAI("/dock-discord")
        ),
        SlashCommand(
            name: "dock-slack",
            description: "切换到Slack",
            icon: "message",
            category: .channel,
            action: .sendToAI("/dock-slack")
        )
    ]

    // 所有命令
    static let allCommands: [SlashCommand] = localCommands + aiCommands

    static func search(query: String) -> [SlashCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        // 如果没有输入任何内容（只有斜杠），显示所有命令
        if trimmed.isEmpty {
            return allCommands
        }

        // 过滤匹配的命令（支持拼音首字母和全名）
        return allCommands.filter { command in
            command.name.lowercased().hasPrefix(trimmed.lowercased()) ||
            command.description.contains(trimmed)
        }
    }
}
