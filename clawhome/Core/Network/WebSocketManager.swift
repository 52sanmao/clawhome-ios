//
//  WebSocketManager.swift
//  contextgo
//
//  Manages legacy WebSocket connection kept separate from the IronClaw HTTP service
//

import Foundation
import Combine

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

class WebSocketManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastError: String?

    // MARK: - Private Properties
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let url: URL
    private var isIntentionalDisconnect = false
    private var reconnectTimer: Timer?
    private let maxReconnectDelay: TimeInterval = 30.0
    private var currentReconnectDelay: TimeInterval = 1.0
    private var hasEverConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3

    // MARK: - Callbacks
    var onMessageReceived: ((Data) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    // MARK: - Initialization
    init(url: URL = URL(string: "ws://localhost:18789")!) {
        self.url = url
        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public Methods
    func connect() {
        guard connectionState != .connecting && connectionState != .connected else {
            print("[WebSocket] Already connecting or connected")
            return
        }

        isIntentionalDisconnect = false
        reconnectAttempts = 0  // Reset reconnect attempts on manual connect
        connectionState = .connecting
        print("[WebSocket] Connecting to \(redactedURLString(url))")

        guard let session = session else {
            connectionState = .error("Session not initialized")
            return
        }

        // Create URLRequest with Origin header for Gateway CORS validation
        var request = URLRequest(url: url)

        // Convert WebSocket URL to HTTP Origin (ws:// → http://, wss:// → https://)
        let originScheme = url.scheme == "wss" ? "https" : "http"
        if let host = url.host {
            let port = url.port ?? (url.scheme == "wss" ? 443 : 80)
            let origin = "\(originScheme)://\(host):\(port)"
            request.setValue(origin, forHTTPHeaderField: "Origin")
            print("[WebSocket] Setting Origin header: \(origin)")
        }

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        // Start listening for messages
        receiveMessage()

        // Connection is established in URLSessionWebSocketDelegate
    }

    func disconnect() {
        print("[WebSocket] Disconnecting...")
        isIntentionalDisconnect = true
        cancelReconnect()

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        connectionState = .disconnected
        onDisconnected?()
    }

    func send(_ message: Encodable) {
        guard connectionState == .connected else {
            print("[WebSocket] Cannot send: not connected")
            return
        }

        do {
            let data = try JSONEncoder().encode(message)
            send(data: data)
        } catch {
            print("[WebSocket] Encoding error: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func send(data: Data) {
        guard connectionState == .connected else {
            print("[WebSocket] Cannot send: not connected")
            return
        }

        let dataSize = data.count
        let dataSizeMB = Double(dataSize) / 1024 / 1024

        print("[WebSocket] ⬆️ Message size: \(dataSize) bytes (\(String(format: "%.2f", dataSizeMB)) MB)")

        // Warning if message is large (>2MB could be problematic for some WebSocket servers)
        if dataSize > 2 * 1024 * 1024 {
            print("[WebSocket] ⚠️ Large message detected (\(String(format: "%.2f", dataSizeMB)) MB) - may cause connection issues")
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            print("[WebSocket] ⬆️ Sending text payload")
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(message) { error in
                if let error = error {
                    print("[WebSocket] Send error: \(error.localizedDescription)")
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Private Methods
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("[WebSocket] ⬇️ Received text payload (\(text.count) chars)")
                    if let data = text.data(using: .utf8) {
                        DispatchQueue.main.async {
                            self.onMessageReceived?(data)
                        }
                    }

                case .data(let data):
                    print("[WebSocket] ⬇️ Received binary data")
                    DispatchQueue.main.async {
                        self.onMessageReceived?(data)
                    }

                @unknown default:
                    print("[WebSocket] Unknown message type")
                }

                // Continue listening
                self.receiveMessage()

            case .failure(let error):
                print("[WebSocket] Receive error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.handleDisconnection(error: error)
                }
            }
        }
    }

    private func handleDisconnection(error: Error?) {
        if let error = error {
            print("[WebSocket] Disconnected with error: \(error.localizedDescription)")
            lastError = error.localizedDescription
            connectionState = .error(error.localizedDescription)
        } else {
            print("[WebSocket] Disconnected")
            connectionState = .disconnected
        }

        onDisconnected?()

        // Auto-reconnect only if:
        // 1. Not intentional disconnect
        // 2. Has connected successfully before (don't retry initial connection)
        // 3. Haven't exceeded max retry attempts
        if !isIntentionalDisconnect && hasEverConnected && reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            print("[WebSocket] Attempt \(reconnectAttempts)/\(maxReconnectAttempts)")
            scheduleReconnect()
        } else if !isIntentionalDisconnect && !hasEverConnected {
            print("[WebSocket] Initial connection failed. Please retry manually.")
        } else if reconnectAttempts >= maxReconnectAttempts {
            print("[WebSocket] Max reconnect attempts reached. Please reconnect manually.")
        }
    }

    private func scheduleReconnect() {
        cancelReconnect()

        print("[WebSocket] Reconnecting in \(currentReconnectDelay)s...")

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: currentReconnectDelay, repeats: false) { [weak self] _ in
            self?.connect()
        }

        // Exponential backoff
        currentReconnectDelay = min(currentReconnectDelay * 2, maxReconnectDelay)
    }

    private func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func resetReconnectDelay() {
        currentReconnectDelay = 1.0
    }

    private func redactedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "\(url.scheme ?? "ws")://\(url.host ?? "unknown")"
    }
}

// MARK: - URLSessionWebSocketDelegate
extension WebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("[WebSocket] ✅ Connection established")

        DispatchQueue.main.async {
            self.hasEverConnected = true
            self.reconnectAttempts = 0
            self.connectionState = .connected
            self.resetReconnectDelay()
            self.onConnected?()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("[WebSocket] Connection closed with code: \(closeCode.rawValue)")

        DispatchQueue.main.async {
            self.handleDisconnection(error: nil)
        }
    }
}

// MARK: - URLSessionDelegate
extension WebSocketManager: URLSessionDelegate {
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            print("[WebSocket] Session invalid: \(error.localizedDescription)")
        }
    }
}
