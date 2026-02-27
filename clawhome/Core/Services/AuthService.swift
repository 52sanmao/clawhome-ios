//
//  AuthService.swift
//  contextgo
//
//  Authentication service for Core API (multi-user JWT)
//

import Foundation
import UIKit

@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var currentUser: User?
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false

    private let coreConfig = CoreConfig.shared
    private let client = CoreAPIClient.shared

    private init() {
        Task { await checkAuthentication() }
    }

    // MARK: - Authentication State

    func checkAuthentication() async {
        guard coreConfig.isConfigured else {
            isAuthenticated = false
            currentUser = nil
            return
        }
        do {
            let user = try await client.getMe()
            currentUser = user
            isAuthenticated = true
            print("✅ [Auth] Authenticated as \(user.email)")

            // Register controller device after successful authentication
            await registerControllerDevice()
        } catch {
            print("⚠️ [Auth] Validation failed: \(error.localizedDescription)")
            isAuthenticated = false
            currentUser = nil
            coreConfig.clearAuth()
        }
    }

    // MARK: - Login / Register

    func login(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        struct Body: Encodable { let email: String; let password: String }
        let response: AuthResponse = try await client.post("/api/auth/login", body: Body(email: email, password: password))

        guard response.success, let token = response.token, let user = response.user else {
            throw NSError(domain: "AuthService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: response.error ?? "登录失败"])
        }
        coreConfig.saveJWT(token)
        coreConfig.userEmail = user.email
        coreConfig.displayName = user.displayName
        currentUser = user
        isAuthenticated = true

        // Register controller device after successful login
        await registerControllerDevice()
    }

    func register(email: String, password: String, displayName: String?) async throws {
        isLoading = true
        defer { isLoading = false }

        struct Body: Encodable { let email: String; let password: String; let displayName: String? }
        let response: AuthResponse = try await client.post("/api/auth/register",
                                                           body: Body(email: email, password: password, displayName: displayName))

        guard response.success, let token = response.token, let user = response.user else {
            throw NSError(domain: "AuthService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: response.error ?? "注册失败"])
        }
        coreConfig.saveJWT(token)
        coreConfig.userEmail = user.email
        coreConfig.displayName = user.displayName
        currentUser = user
        isAuthenticated = true

        // Register controller device after successful registration
        await registerControllerDevice()
    }

    // MARK: - Logout

    func logout() async {
        do {
            struct Empty: Encodable {}
            struct LogoutResp: Decodable {}
            let _: LogoutResp = try await client.post("/api/auth/logout", body: Empty())
        } catch {
            print("⚠️ [Auth] Logout API: \(error.localizedDescription)")
        }
        coreConfig.clearAuth()
        currentUser = nil
        isAuthenticated = false
    }

    // MARK: - Device Registration

    /// Register this iOS device as a controller in Core (best-effort, called after login)
    private func registerControllerDevice() async {
        guard coreConfig.isConfigured else {
            print("⚠️ [Auth] Device registration skipped: Core not configured")
            return
        }

        // Send vendor UUID to Core, which will generate device_xxx ID
        let vendorId = coreConfig.vendorUUID
        let deviceName = UIDevice.current.name
        let osVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        do {
            let device = try await client.registerDevice(
                deviceId: vendorId,  // Core will generate device_xxx from this
                deviceName: deviceName,
                kind: "controller",
                osVersion: osVersion,
                appVersion: appVersion
            )
            print("✅ [Auth] Controller device registered: \(device.deviceId) (vendor: \(vendorId.prefix(8))...)")
        } catch {
            print("⚠️ [Auth] Device registration failed: \(error.localizedDescription)")
        }
    }
}
