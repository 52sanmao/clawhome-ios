//
//  TerminalAuthService.swift
//  contextgo
//
//  E2E encrypted terminal authorization service
//  Handles the App side of the Happy pairing flow:
//  1. Create account on Happy server (POST /v1/auth) → get JWT token
//  2. Encrypt master public key using NaCl box
//  3. Approve terminal auth request (POST /v1/auth/response)
//

import Foundation

@MainActor
class TerminalAuthService: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var isAuthorized: Bool = false

    /// The token received after account creation (available after successful auth)
    private(set) var authToken: String?
    /// The master secret used (available after successful auth)
    private(set) var masterSecret: Data?

    private let crypto = NaClCrypto.shared

    // MARK: - Terminal Authorization

    /// Full terminal authorization flow:
    /// 1. Create NEW master secret (new account, not shared)
    /// 2. Create/login account on Happy server → get JWT token
    /// 3. Encrypt master box public key for CLI
    /// 4. POST encrypted response to approve the terminal auth request
    ///
    /// NOTE: Master secret is NOT stored in Keychain, caller must persist it in the active agent config.
    func authorizeTerminal(cliPublicKeyBase64: String) async throws {
        isLoading = true
        error = nil
        isAuthorized = false

        defer { isLoading = false }

        do {
            // 1. Decode CLI's ephemeral public key
            guard let cliPublicKey = crypto.decodeBase64URL(cliPublicKeyBase64),
                  cliPublicKey.count == NaClCrypto.publicKeySize else {
                throw AuthError.invalidPublicKey
            }
            print("[TerminalAuth] CLI public key: \(cliPublicKeyBase64.prefix(12))...")

            // 2. Create NEW master secret (32 random bytes)
            // Each bot = independent account (not shared across bots)
            var secret = Data(count: 32)
            secret.withUnsafeMutableBytes { buffer in
                _ = SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
            }
            self.masterSecret = secret
            print("[TerminalAuth] New master secret created (32 bytes)")

            // 3. Get server config
            guard let serverConfig = getServerConfig() else {
                throw AuthError.noServerConfig
            }

            // 4. Create account / login to get JWT token
            let token = try await createAccount(serverURL: serverConfig.serverURL, masterSecret: secret)
            self.authToken = token
            print("[TerminalAuth] Account created, got token: \(token.prefix(12))...")

            // 5. Derive content key pair public key from master secret
            //    This mirrors Happy's: deriveKey(masterSecret, 'Happy EnCoder', ['content'])
            //    → crypto_box_seed_keypair → publicKey
            let contentPublicKey = try crypto.deriveContentPublicKey(masterSecret: secret)
            print("[TerminalAuth] Content public key derived via HMAC-SHA512 tree")

            // 6. Build V2 payload: [version_flag(1)] [content_public_key(32)]
            var payload = Data(count: 33)
            payload[0] = 0  // Version 2 flag (Data Key mode)
            payload.replaceSubrange(1..<33, with: contentPublicKey)
            print("[TerminalAuth] V2 payload built (33 bytes)")

            // 7. Encrypt payload with CLI's ephemeral public key
            let encryptedBundle = try crypto.encryptWithEphemeralKey(
                message: payload,
                recipientPublicKey: cliPublicKey
            )
            print("[TerminalAuth] Payload encrypted (\(encryptedBundle.count) bytes)")

            // 8. POST /v1/auth/response to approve terminal auth
            // Server expects standard base64 (not base64URL) for publicKey
            let cliPublicKeyStdBase64 = cliPublicKey.base64EncodedString()
            try await postAuthResponse(
                serverURL: serverConfig.serverURL,
                token: token,
                cliPublicKey: cliPublicKeyStdBase64,
                encryptedResponse: encryptedBundle.base64EncodedString()
            )

            isAuthorized = true
            print("[TerminalAuth] Authorization successful!")

        } catch {
            self.error = error.localizedDescription
            print("[TerminalAuth] Authorization failed: \(error)")
            throw error
        }
    }

    // MARK: - Account Creation (POST /v1/auth)

    /// Create or login to a Happy account using Ed25519 challenge-response
    /// Returns the JWT token for subsequent API calls
    private func createAccount(serverURL: String, masterSecret: Data) async throws -> String {
        guard let url = URL(string: "\(serverURL)/v1/auth") else {
            throw AuthError.invalidServerURL
        }

        // Derive Ed25519 signing key pair from master secret (used as seed)
        let signKeyPair = try crypto.signKeyPairFromSeed(masterSecret)
        print("[TerminalAuth] Ed25519 signing key pair derived")

        // Generate random challenge
        let challenge = try crypto.randomBytes(32)

        // Sign the challenge
        let signature = try crypto.signDetached(message: challenge, secretKey: signKeyPair.secretKey)
        print("[TerminalAuth] Challenge signed")

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: String] = [
            "publicKey": signKeyPair.publicKey.base64EncodedString(),
            "challenge": challenge.base64EncodedString(),
            "signature": signature.base64EncodedString()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[TerminalAuth] POST /v1/auth to \(serverURL)")

        // Retry once if iOS network permission check fails (-1009)
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AuthError.networkError("Invalid response")
                }

                print("[TerminalAuth] /v1/auth response status: \(httpResponse.statusCode)")
                print("[TerminalAuth] /v1/auth response body: \(String(data: data, encoding: .utf8) ?? "empty")")

                guard httpResponse.statusCode == 200 else {
                    if httpResponse.statusCode == 401 {
                        throw AuthError.unauthorized
                    }
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw AuthError.serverError(httpResponse.statusCode, errorBody)
                }

                // Parse token from response
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["token"] as? String else {
                    throw AuthError.networkError("Server response missing token")
                }

                return token
            } catch {
                lastError = error
                let nsError = error as NSError

                // Auto-retry once for iOS network permission check error
                if attempt == 1 && nsError.domain == NSURLErrorDomain && nsError.code == -1009 {
                    print("[TerminalAuth] ⚠️ Network permission check failed (attempt \(attempt)), retrying...")
                    try await Task.sleep(nanoseconds: 500_000_000)  // Wait 500ms
                    continue
                }

                throw error
            }
        }

        throw lastError ?? AuthError.networkError("Unknown error")
    }

    // MARK: - Approve Terminal Auth (POST /v1/auth/response)

    private func postAuthResponse(
        serverURL: String,
        token: String,
        cliPublicKey: String,
        encryptedResponse: String
    ) async throws {
        guard let url = URL(string: "\(serverURL)/v1/auth/response") else {
            throw AuthError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: String] = [
            "publicKey": cliPublicKey,
            "response": encryptedResponse
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[TerminalAuth] POST /v1/auth/response to \(serverURL)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }

        print("[TerminalAuth] /v1/auth/response status: \(httpResponse.statusCode)")
        print("[TerminalAuth] /v1/auth/response body: \(String(data: data, encoding: .utf8) ?? "empty")")

        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success {
                print("[TerminalAuth] Server accepted terminal auth response")
            }
        } else if httpResponse.statusCode == 401 {
            throw AuthError.unauthorized
        } else if httpResponse.statusCode == 404 {
            throw AuthError.networkError("Terminal auth request not found. CLI may have timed out. Please try scanning a new QR code.")
        } else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError(httpResponse.statusCode, errorBody)
        }
    }

    // MARK: - URL Parsing

    func parsePublicKeyFromURL(_ url: URL) -> String? {
        guard url.scheme == "ctxgo",
              url.host == "terminal" else {
            return nil
        }
        return url.query
    }

    func parsePublicKeyFromWebURL(_ url: URL) -> String? {
        guard let fragment = url.fragment, fragment.hasPrefix("key=") else {
            return nil
        }
        return String(fragment.dropFirst(4))
    }

    // MARK: - Server Config

    struct ServerConfig {
        let serverURL: String
    }

    var activeServerConfig: ServerConfig? = nil

    private func getServerConfig() -> ServerConfig? {
        if let config = activeServerConfig { return config }
        let url = CoreConfig.shared.cliRelayServerURL
        return ServerConfig(serverURL: url.isEmpty ? CoreServerDefaults.relayServerURL : url)
    }

    // MARK: - Errors

    enum AuthError: Error, LocalizedError {
        case invalidURL
        case invalidQRCode
        case invalidPublicKey
        case noServerConfig
        case invalidServerURL
        case unauthorized
        case networkError(String)
        case serverError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "无效的授权链接"
            case .invalidQRCode:
                return "无效的 QR 码格式"
            case .invalidPublicKey:
                return "无效的公钥"
            case .noServerConfig:
                return "未配置 ContextGo Server 地址"
            case .invalidServerURL:
                return "无效的服务器地址"
            case .unauthorized:
                return "授权被拒绝，签名验证失败"
            case .networkError(let msg):
                return "网络错误: \(msg)"
            case .serverError(let code, let msg):
                return "服务器错误 (\(code)): \(msg)"
            }
        }
    }
}
