//
//  ConnectionManager.swift
//  clawhome
//
//  IronClaw-backed connection manager
//

import Foundation
import Combine

@MainActor
class ConnectionManager: ObservableObject {
    // MARK: - Singleton
    static let shared = ConnectionManager()

    // MARK: - Published Properties
    @Published private(set) var connectionStates: [String: ConnectionState] = [:]  // agentId -> state

    // MARK: - Private Properties
    private var clients: [String: OpenClawClient] = [:]  // agentId -> OpenClawClient
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    private init() {
        print("[ConnectionManager] Initializing IronClaw-backed manager")
    }

    // MARK: - Public API

    /// Get or create OpenClawClient for a specific agent.
    func getClient(for agentId: String, gatewayURL: String? = nil, token: String? = nil) -> OpenClawClient {
        let parsedGateway = gatewayURL.map { CoreConfig.parseGatewayConfiguration(endpoint: $0) }
        let normalizedGatewayURL = parsedGateway?.baseURL
        let extractedToken = parsedGateway?.token
        let trimmedToken = (token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? token?.trimmingCharacters(in: .whitespacesAndNewlines)
            : extractedToken) ?? ""
        if let existingClient = clients[agentId] {
            if !trimmedToken.isEmpty {
                CoreConfig.shared.saveJWT(trimmedToken)
                print("[ConnectionManager] Reusing client for \(agentId) with refreshed token source=\(token?.isEmpty == false ? "agent-specific" : "url-query")")
            }
            return existingClient
        }

        let gatewayURLString = normalizedGatewayURL ?? CoreConfig.shared.openClawGatewayURL
        if !trimmedToken.isEmpty {
            CoreConfig.shared.saveJWT(trimmedToken)
        }
        let tokenProvider: () -> String = {
            if !trimmedToken.isEmpty {
                return trimmedToken
            }
            return CoreConfig.shared.jwtToken
        }
        let tokenLabel = !trimmedToken.isEmpty
            ? (token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "agent-specific token" : "url-query token")
            : "CoreConfig.shared.jwtToken"

        print("[ConnectionManager] Preparing client agent=\(agentId) gateway=\(gatewayURLString) tokenLabel=\(tokenLabel)")

        guard let url = URL(string: gatewayURLString) else {
            let defaultURL = URL(string: CoreConfig.shared.openClawGatewayURL)!
            let client = OpenClawClient(url: defaultURL, tokenProvider: tokenProvider, tokenLabel: tokenLabel)
            clients[agentId] = client
            setupClientBindings(client: client, agentId: agentId)
            return client
        }

        let client = OpenClawClient(url: url, tokenProvider: tokenProvider, tokenLabel: tokenLabel)
        clients[agentId] = client
        setupClientBindings(client: client, agentId: agentId)
        return client
    }


    func connect(agentId: String, gatewayURL: String? = nil, token: String? = nil) {
        if let gatewayURL {
            let parsed = CoreConfig.parseGatewayConfiguration(endpoint: gatewayURL)
            if let extractedToken = parsed.token, !extractedToken.isEmpty, (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CoreConfig.shared.saveJWT(extractedToken)
                print("[ConnectionManager] Extracted token from gateway URL for agent=\(agentId)")
            }
        }
        let client = getClient(for: agentId, gatewayURL: gatewayURL, token: token)
        client.connect()
    }

    func disconnect(agentId: String) {
        guard let client = clients[agentId] else { return }
        client.disconnect()
    }

    func disconnectAll() {
        for (_, client) in clients {
            client.disconnect()
        }
    }

    func removeClient(agentId: String) {
        guard let client = clients.removeValue(forKey: agentId) else { return }
        client.disconnect()
        connectionStates.removeValue(forKey: agentId)
    }

    func getConnectionState(agentId: String) -> ConnectionState {
        connectionStates[agentId] ?? .disconnected
    }

    func isConnected(agentId: String) -> Bool {
        clients[agentId]?.isConnected ?? false
    }

    func updateConnectionState(agentId: String, state: ConnectionState) {
        connectionStates[agentId] = state
    }

    // MARK: - Private Methods

    private func setupClientBindings(client: OpenClawClient, agentId: String) {
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionStates[agentId] = state
            }
            .store(in: &cancellables)
    }
}
