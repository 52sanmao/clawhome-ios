//
//  ConnectionManager.swift
//  clawhome
//
//  OpenClaw-only connection manager
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
        print("[ConnectionManager] Initializing OpenClaw-only manager")
    }

    // MARK: - Public API

    /// Get or create OpenClawClient for a specific agent.
    func getClient(for agentId: String, gatewayURL: String? = nil) -> OpenClawClient {
        if let existingClient = clients[agentId] {
            return existingClient
        }

        let gatewayURLString = gatewayURL ?? CoreConfig.shared.openClawGatewayURL
        guard let url = URL(string: gatewayURLString) else {
            let defaultURL = URL(string: CoreConfig.shared.openClawGatewayURL)!
            let client = OpenClawClient(url: defaultURL)
            clients[agentId] = client
            setupClientBindings(client: client, agentId: agentId)
            return client
        }

        let client = OpenClawClient(url: url)
        clients[agentId] = client
        setupClientBindings(client: client, agentId: agentId)
        return client
    }

    func connect(agentId: String, gatewayURL: String? = nil) {
        let client = getClient(for: agentId, gatewayURL: gatewayURL)
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
