import Foundation

extension Skill {
    enum RenderState: Int {
        case blocked = 0
        case needsSetup = 1
        case disabled = 2
        case enabled = 3
        case alwaysOn = 4
    }

    var displayName: String {
        name.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    var isEnabled: Bool {
        !disabled
    }

    var isInstalled: Bool {
        missing.bins.isEmpty &&
        (missing.anyBins?.isEmpty ?? true) &&
        (missing.env?.isEmpty ?? true) &&
        (missing.config?.isEmpty ?? true) &&
        (missing.os?.isEmpty ?? true)
    }

    var missingBinsList: [String] {
        var values = missing.bins
        values.append(contentsOf: missing.anyBins ?? [])
        return Array(Set(values)).sorted()
    }

    var missingEnvList: [String] {
        (missing.env ?? []).sorted()
    }

    var missingConfigList: [String] {
        (missing.config ?? []).sorted()
    }

    var missingOSList: [String] {
        (missing.os ?? []).sorted()
    }

    var isBlockedByPolicy: Bool {
        blockedByAllowlist == true || eligible == false
    }

    var renderState: RenderState {
        if disabled {
            return .disabled
        }
        if isBlockedByPolicy {
            return .blocked
        }
        if !isInstalled {
            return .needsSetup
        }
        if always && !disabled {
            return .alwaysOn
        }
        return .enabled
    }

    var renderPriority: Int {
        renderState.rawValue
    }

    var blockerSummary: String? {
        if blockedByAllowlist == true {
            return "受 allowlist 限制，当前会话不可用"
        }
        if eligible == false {
            return "当前环境不满足启用条件"
        }
        if !missingOSList.isEmpty {
            return "系统限制: \(missingOSList.joined(separator: ", "))"
        }
        if !missingEnvList.isEmpty {
            return "缺少环境变量: \(missingEnvList.prefix(3).joined(separator: ", "))"
        }
        if !missingConfigList.isEmpty {
            return "缺少配置项: \(missingConfigList.prefix(3).joined(separator: ", "))"
        }
        if !missingBinsList.isEmpty {
            return "缺少依赖: \(missingBinsList.prefix(3).joined(separator: ", "))"
        }
        return nil
    }

    var blockerTags: [String] {
        var tags: [String] = []
        if blockedByAllowlist == true {
            tags.append("白名单限制")
        }
        if eligible == false {
            tags.append("环境不匹配")
        }
        if !missingOSList.isEmpty {
            tags.append("系统")
        }
        if !missingBinsList.isEmpty {
            tags.append("依赖")
        }
        if !missingEnvList.isEmpty {
            tags.append("环境变量")
        }
        if !missingConfigList.isEmpty {
            tags.append("配置")
        }
        return tags
    }

    var installHints: [String] {
        (install ?? []).map { config in
            let bins = (config.bins ?? []).joined(separator: ", ")
            if bins.isEmpty {
                return config.label
            }
            return "\(config.label) (\(bins))"
        }
    }

    var statusColor: String {
        switch renderState {
        case .alwaysOn:
            return "cyan"
        case .enabled:
            return "green"
        case .disabled:
            return "orange"
        case .needsSetup:
            return "blue"
        case .blocked:
            return "red"
        }
    }

    var statusText: String {
        switch renderState {
        case .alwaysOn:
            return "常驻启用"
        case .enabled:
            return "已启用"
        case .disabled:
            return "已禁用"
        case .needsSetup:
            return "待配置"
        case .blocked:
            return "受限"
        }
    }

    var sourceDisplayName: String {
        switch source {
        case "openclaw-workspace":
            return "工作区"
        case "openclaw-bundled":
            return "内置"
        case "openclaw-managed":
            return "托管"
        default:
            return source
        }
    }
}
