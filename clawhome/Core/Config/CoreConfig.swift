//
//  CoreConfig.swift
//  contextgo
//
//  ContextGo Core 连接配置 — 支持多用户 JWT 认证
//  JWT token 存储在 Keychain，endpoint 存储在 UserDefaults
//

import Foundation
import SwiftUI
import Security
import UIKit

enum CoreServerDefaults {
    static let coreEndpoint = "https://example.com"
    static let relayServerURL = "https://example.com"
    static let openClawGatewayURL = "ws://127.0.0.1:18789"
}

enum ASRServiceConfig {
    enum Alibaba {
        static let defaultWSURL = "wss://dashscope.aliyuncs.com/api-ws/v1/inference/"
        static let apiKeyEnvironmentKey = "ASR_DASHSCOPE_API_KEY"
        static let wsURLEnvironmentKey = "ASR_DASHSCOPE_WS_URL"

        private static let apiKeyInfoPlistKey = "ASR_DASHSCOPE_API_KEY"
        private static let wsURLInfoPlistKey = "ASR_DASHSCOPE_WS_URL"

        static var wsURL: String {
            configuredValue(environmentKey: wsURLEnvironmentKey, infoPlistKey: wsURLInfoPlistKey) ?? defaultWSURL
        }

        static var apiKey: String {
            configuredValue(environmentKey: apiKeyEnvironmentKey, infoPlistKey: apiKeyInfoPlistKey) ?? ""
        }

        private static func configuredValue(environmentKey: String, infoPlistKey: String) -> String? {
            let environmentValue = ProcessInfo.processInfo.environment[environmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let environmentValue, !environmentValue.isEmpty {
                return environmentValue
            }

            let infoPlistValue = (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let infoPlistValue, !infoPlistValue.isEmpty {
                return infoPlistValue
            }

            return nil
        }
    }
}

/// 存储 contextgo-core 服务的连接配置（多用户 JWT 模式）
@MainActor
class CoreConfig: ObservableObject {
    static let shared = CoreConfig()

    static func endpointBaseURL(from raw: String) -> URL? {
        let normalized = normalizeEndpoint(raw)
        guard !normalized.isEmpty else { return nil }
        guard var components = URLComponents(string: normalized),
              let host = components.host,
              !host.isEmpty,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func composeURL(endpoint raw: String, path: String) -> URL? {
        guard let baseURL = endpointBaseURL(from: raw),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = normalizedPath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func normalizeEndpoint(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: withScheme),
              let host = components.host,
              !host.isEmpty,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return trimmed
        }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil

        var normalized = "\(scheme)://\(host.lowercased())"
        if let port = components.port {
            let defaultPort = (scheme == "https") ? 443 : 80
            if port != defaultPort {
                normalized += ":\(port)"
            }
        }
        return normalized
    }

    // MARK: - Keychain keys

    private static let keychainJWTKey = "io.contextgo.ios.coreJWTToken"
    private static let keychainServiceKey = "io.contextgo.ios"

    // MARK: - Stored properties

    @Published var endpoint: String {
        didSet {
            let normalized = CoreConfig.normalizeEndpoint(endpoint)
            if endpoint != normalized {
                endpoint = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "coreEndpoint")
        }
    }

    @Published var userEmail: String {
        didSet {
            UserDefaults.standard.set(userEmail, forKey: "coreUserEmail")
        }
    }

    @Published var displayName: String {
        didSet {
            UserDefaults.standard.set(displayName, forKey: "coreDisplayName")
        }
    }

    /// 中继服务器地址（CLI relay server）
    @Published var cliRelayServerURL: String {
        didSet {
            UserDefaults.standard.set(cliRelayServerURL, forKey: "cliRelayServerURL")
        }
    }

    /// OpenClaw 网关地址（默认兜底，仅在 Agent 未提供 wsURL 时使用）
    @Published var openClawGatewayURL: String {
        didSet {
            UserDefaults.standard.set(openClawGatewayURL, forKey: "openClawGatewayURL")
        }
    }

    /// CLI 会话是否优先使用原生 Swift 页面（全原生改造开关）
    @Published var cliNativeExperienceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cliNativeExperienceEnabled, forKey: "cliNativeExperienceEnabled")
        }
    }

    /// JWT token — 存储在 Keychain
    @Published var jwtToken: String = ""

    /// 是否已完成配置（endpoint 非空且已登录）
    var isConfigured: Bool {
        !endpoint.isEmpty && !jwtToken.isEmpty
    }

    /// Vendor UUID（iOS 设备唯一标识符，发送给 Core 用于生成 device_xxx ID）
    lazy var vendorUUID: String = {
        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }()

    private init() {
        let storedEndpoint = UserDefaults.standard.string(forKey: "coreEndpoint") ?? CoreServerDefaults.coreEndpoint
        self.endpoint = CoreConfig.normalizeEndpoint(storedEndpoint)
        self.userEmail = UserDefaults.standard.string(forKey: "coreUserEmail") ?? ""
        self.displayName = UserDefaults.standard.string(forKey: "coreDisplayName") ?? ""
        self.cliRelayServerURL = UserDefaults.standard.string(forKey: "cliRelayServerURL") ?? CoreServerDefaults.relayServerURL
        self.openClawGatewayURL =
            UserDefaults.standard.string(forKey: "openClawGatewayURL")
            ?? UserDefaults.standard.string(forKey: "gatewayURL") // legacy key migration
            ?? CoreServerDefaults.openClawGatewayURL
        self.cliNativeExperienceEnabled = UserDefaults.standard.object(forKey: "cliNativeExperienceEnabled") as? Bool ?? true
        self.jwtToken = CoreConfig.loadJWTFromKeychain() ?? ""
        UserDefaults.standard.set(self.endpoint, forKey: "coreEndpoint")
    }

    // MARK: - Token Management

    func saveJWT(_ token: String) {
        CoreConfig.saveJWTToKeychain(token)
        jwtToken = token
    }

    func clearAuth() {
        CoreConfig.deleteJWTFromKeychain()
        jwtToken = ""
        userEmail = ""
        displayName = ""
    }

    // MARK: - Keychain Helpers

    private static func saveJWTToKeychain(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceKey,
            kSecAttrAccount as String: keychainJWTKey,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        _ = deleteStatus

        let addQuery = query.merging(attributes) { $1 }
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func loadJWTFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceKey,
            kSecAttrAccount as String: keychainJWTKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteJWTFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceKey,
            kSecAttrAccount as String: keychainJWTKey,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
