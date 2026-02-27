//
//  QRScannerView.swift
//  contextgo
//
//  QR code scanner for CLI relay pairing
//  Uses AVFoundation for camera access and QR detection
//

import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = QRScannerViewModel()

    let onScanComplete: (QRPairingData) -> Void

    var body: some View {
        ZStack {
            // Camera preview
            CameraPreview(session: viewModel.session)
                .ignoresSafeArea()

            // Scanning overlay
            VStack {
                Spacer()

                // Scanning frame
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 280, height: 280)

                    // Corner decorations
                    VStack {
                        HStack {
                            CLICornerBracket(rotation: 0)
                            Spacer()
                            CLICornerBracket(rotation: 90)
                        }
                        Spacer()
                        HStack {
                            CLICornerBracket(rotation: 270)
                            Spacer()
                            CLICornerBracket(rotation: 180)
                        }
                    }
                    .frame(width: 280, height: 280)
                }
                .padding()

                // Instructions
                Text("将 QR 码对准取景框")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                    .padding(.bottom, 20)

                // Status message
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(12)
                }

                Spacer()

                // Manual input button
                Button {
                    dismiss()
                } label: {
                    Text("手动输入")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white, Color.black.opacity(0.6))
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .onAppear {
            viewModel.startScanning()
            viewModel.onScanComplete = { data in
                onScanComplete(data)
                dismiss()
            }
        }
        .onDisappear {
            viewModel.stopScanning()
        }
        .alert("扫描错误", isPresented: $viewModel.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }
}

// MARK: - Corner Bracket

struct CLICornerBracket: View {
    let rotation: Double

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.blue)
                .frame(width: 4, height: 30)
            Rectangle()
                .fill(Color.blue)
                .frame(width: 30, height: 4)
        }
        .rotationEffect(.degrees(rotation))
    }
}

// MARK: - Camera Preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = uiView.bounds
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - QR Scanner ViewModel

@MainActor
class QRScannerViewModel: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    let session = AVCaptureSession()
    private var videoOutput = AVCaptureMetadataOutput()
    private var hasScanned: Bool = false  // Prevent duplicate scan callbacks

    var onScanComplete: ((QRPairingData) -> Void)?

    func startScanning() {
        hasScanned = false  // Reset for new scanning session
        // Check camera authorization
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.setupCamera()
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.errorMessage = "需要相机权限才能扫描 QR 码"
                        self?.showError = true
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = "请在设置中允许访问相机"
            showError = true
        @unknown default:
            break
        }
    }

    func stopScanning() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            errorMessage = "无法访问摄像头"
            showError = true
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)

            if session.canAddInput(input) {
                session.addInput(input)
            }

            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                videoOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                videoOutput.metadataObjectTypes = [.qr]
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        } catch {
            errorMessage = "相机设置失败: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let metadataObject = metadataObjects.first,
              let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue else {
            return
        }

        // Parse QR code data
        Task { @MainActor in
            handleScannedCode(stringValue)
        }
    }

    private func handleScannedCode(_ code: String) {
        // Prevent duplicate callbacks - AVCaptureMetadataOutput fires multiple times
        guard !hasScanned else { return }
        hasScanned = true

        // Stop scanning after successful scan
        stopScanning()

        print("[QRScanner] Raw scanned content: \(code)")

        // Parse QR code (expected format: JSON with serverURL and token)
        if let data = parseQRCode(code) {
            print("[QRScanner] Parsed successfully - isTerminalAuth: \(data.isTerminalAuth), serverURL: \(data.serverURL), terminalPublicKey: \(data.terminalPublicKey?.prefix(12) ?? "nil")...")
            onScanComplete?(data)
        } else {
            print("[QRScanner] Failed to parse QR code content")
            errorMessage = "无效的 QR 码格式"
            showError = true
        }
    }

    private func parseQRCode(_ code: String) -> QRPairingData? {
        print("[QRScanner] Parsing QR code: \(code.prefix(80))...")

        // Terminal auth format: ctxgo://terminal?{base64url(json)}
        if code.hasPrefix("ctxgo://terminal?") {
            let ctxgoPrefix = "ctxgo://terminal?"
            let payload = String(code.dropFirst(ctxgoPrefix.count))
            print("[QRScanner] Detected terminal auth format, payload: \(payload.prefix(40))...")

            // Try to decode as base64url JSON
            if let jsonData = Data(base64URLEncoded: payload),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                print("[QRScanner] Decoded JSON payload: \(json)")

                // Support both new short names (v1) and old long names for backward compat
                let version = json["v"] as? Int
                let type = (json["t"] ?? json["type"]) as? String
                let key = (json["k"] ?? json["key"]) as? String
                let ts = (json["ts"] as? NSNumber).map { Int64(truncating: $0) }
                let nonce = (json["n"] ?? json["nonce"]) as? String
                let machineId = (json["m"] ?? json["machineId"]) as? String
                let runtimeServer = (json["rs"] ?? json["runtimeServer"]) as? String

                if let key = key {
                    let pairingData = QRPairingData(
                        serverURL: "",
                        token: "",
                        terminalPublicKey: key,
                        agentType: type,
                        version: version,
                        timestamp: ts,
                        nonce: nonce,
                        machineId: machineId,
                        runtimeServer: runtimeServer
                    )

                    // Validate the payload
                    do {
                        try pairingData.validateTerminalAuth()
                        print("[QRScanner] ✅ Payload validated successfully")
                        print("[QRScanner]    - version: \(version ?? 0)")
                        print("[QRScanner]    - type: \(type ?? "nil")")
                        print("[QRScanner]    - key: \(key.prefix(12))...")
                        print("[QRScanner]    - timestamp: \(ts ?? 0)")
                        print("[QRScanner]    - nonce: \(nonce?.prefix(8) ?? "nil")...")
                        return pairingData
                    } catch {
                        print("[QRScanner] ❌ Payload validation failed: \(error.localizedDescription)")
                        errorMessage = "QR code validation failed: \(error.localizedDescription)"
                        showError = true
                        return nil
                    }
                }
            }

            print("[QRScanner] ❌ Invalid terminal payload format")
            return nil
        }

        // Account link format: ctxgo:///account?{base64PublicKey}
        if code.hasPrefix("ctxgo:///account?") {
            let ctxgoPrefix = "ctxgo:///account?"
            let publicKey = String(code.dropFirst(ctxgoPrefix.count))
            print("[QRScanner] Detected account link format, publicKey: \(publicKey.prefix(12))...")
            if !publicKey.isEmpty {
                return QRPairingData(
                    serverURL: "",
                    token: "",
                    terminalPublicKey: publicKey
                )
            }
        }

        // Try parsing as JSON
        if let data = code.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let serverURL = json["serverURL"],
           let token = json["token"] {

            let secretKey = json["secretKey"]?.data(using: .utf8)
            return QRPairingData(
                serverURL: serverURL,
                token: token,
                secretKey: secretKey
            )
        }

        // Fallback: Try parsing as URL with query parameters
        if let url = URL(string: code),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {

            let queryItems = components.queryItems ?? []
            let serverURL = queryItems.first(where: { $0.name == "serverURL" })?.value
            let token = queryItems.first(where: { $0.name == "token" })?.value
            let secretKey = queryItems.first(where: { $0.name == "secretKey" })?.value?.data(using: .utf8)

            if let serverURL = serverURL, let token = token {
                return QRPairingData(
                    serverURL: serverURL,
                    token: token,
                    secretKey: secretKey
                )
            }
        }

        return nil
    }
}

// MARK: - QR Pairing Data

struct QRPairingData {
    let serverURL: String
    let token: String
    let secretKey: Data?

    // Terminal auth (E2E encrypted pairing) - NEW FORMAT
    let terminalPublicKey: String?  // CLI's ephemeral public key (base64url)
    let agentType: String?
    let version: Int?               // Payload version (expected: 1)
    let timestamp: Int64?           // Payload creation timestamp (ms)
    let nonce: String?              // Anti-replay nonce
    let machineId: String?
    let runtimeServer: String?

    init(serverURL: String, token: String, secretKey: Data? = nil, terminalPublicKey: String? = nil, agentType: String? = nil, version: Int? = nil, timestamp: Int64? = nil, nonce: String? = nil, machineId: String? = nil, runtimeServer: String? = nil) {
        self.serverURL = serverURL
        self.token = token
        self.secretKey = secretKey
        self.terminalPublicKey = terminalPublicKey
        self.agentType = agentType
        self.version = version
        self.timestamp = timestamp
        self.nonce = nonce
        self.machineId = machineId
        self.runtimeServer = runtimeServer
    }

    /// Whether this is a terminal authorization QR code
    var isTerminalAuth: Bool {
        return terminalPublicKey != nil
    }

    /// Validate terminal auth payload
    func validateTerminalAuth() throws {
        guard isTerminalAuth else {
            throw ValidationError.notTerminalAuth
        }

        // Validate version
        guard let v = version else {
            throw ValidationError.missingVersion
        }
        if v != 1 {
            throw ValidationError.unsupportedVersion(v)
        }

        // Validate agent type
        guard let type = agentType, !type.isEmpty else {
            throw ValidationError.missingAgentType
        }
        let normalizedType = type.lowercased()
        let allowedTypes = ["claudecode", "codex", "geminicli", "opencode"]
        if !allowedTypes.contains(normalizedType) {
            throw ValidationError.invalidAgentType(type)
        }

        // Validate public key length (should decode to 32 bytes)
        guard let key = terminalPublicKey, !key.isEmpty else {
            throw ValidationError.invalidPublicKey
        }
        guard let keyData = Data(base64URLEncoded: key), keyData.count == 32 else {
            throw ValidationError.invalidPublicKey
        }

        // Validate freshness (within 10 minutes)
        guard let ts = timestamp else {
            throw ValidationError.missingTimestamp
        }
        let now = Date().timeIntervalSince1970 * 1000  // Convert to ms
        let age = now - Double(ts)
        let maxAge = 10 * 60 * 1000.0  // 10 minutes in ms
        if age > maxAge {
            throw ValidationError.expired(ageMinutes: Int(age / 60000))
        }
        if age < 0 {
            throw ValidationError.futureTimestamp
        }

        // Validate nonce presence
        guard let n = nonce else {
            throw ValidationError.missingNonce
        }
        if n.isEmpty {
            throw ValidationError.emptyNonce
        }
    }

    enum ValidationError: Error, LocalizedError {
        case notTerminalAuth
        case missingVersion
        case missingAgentType
        case missingTimestamp
        case missingNonce
        case unsupportedVersion(Int)
        case invalidAgentType(String)
        case invalidPublicKey
        case expired(ageMinutes: Int)
        case futureTimestamp
        case emptyNonce
        case agentTypeMismatch(expected: String, got: String)

        var errorDescription: String? {
            switch self {
            case .notTerminalAuth:
                return "Not a terminal authorization QR code"
            case .missingVersion:
                return "Missing payload version"
            case .missingAgentType:
                return "Missing agent type"
            case .missingTimestamp:
                return "Missing payload timestamp"
            case .missingNonce:
                return "Missing nonce value"
            case .unsupportedVersion(let v):
                return "Unsupported payload version: \(v)"
            case .invalidAgentType(let type):
                return "Invalid agent type: \(type). Allowed: claudecode, codex, geminicli, opencode"
            case .invalidPublicKey:
                return "Invalid public key format (must be 32-byte base64url)"
            case .expired(let age):
                return "QR code expired (\(age) minutes old, max 10 minutes)"
            case .futureTimestamp:
                return "QR code has future timestamp (clock skew?)"
            case .emptyNonce:
                return "Empty nonce value"
            case .agentTypeMismatch(let expected, let got):
                return "Agent type mismatch: expected \(expected), got \(got)"
            }
        }
    }
}

// MARK: - Base64URL Extension

extension Data {
    /// Initialize Data from base64url encoded string
    /// Base64url uses `-` instead of `+` and `_` instead of `/`, and omits padding
    init?(base64URLEncoded string: String) {
        // Convert base64url to standard base64
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        // Use standard base64 decoding
        self.init(base64Encoded: base64)
    }
}

// MARK: - Preview

#Preview {
    QRScannerView { data in
        print("Scanned: \(data.serverURL)")
    }
}
