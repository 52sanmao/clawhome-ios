//
//  QRCodeScannerView.swift
//  contextgo
//
//  QR Code Scanner for adding bot channels
//

import SwiftUI
import UIKit
import AVFoundation

struct QRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var scannedURL: String?
    var agentType: String?  // 可选的 Agent Type，用于显示不同的提示文字

    @StateObject private var scannerDelegate = QRScannerDelegate()
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isScanning = true
    @State private var showPhotoPicker = false
    @State private var selectedImage: UIImage?
    @State private var showManualInput = false
    @State private var manualURL = ""

    // 根据 Agent Type 返回提示文字
    private var hintText: String {
        guard let agentType = agentType else {
            return "支持 OpenClaw 网关加密连接"
        }

        switch agentType {
        case "OpenClaw":
            return "支持 OpenClaw 网关加密连接"
        case "Claude Code":
            return "支持 Claude Code 配对连接"
        case "CodeX":
            return "支持 CodeX 配对连接"
        case "OpenCode":
            return "支持 OpenCode 配对连接"
        case "Gemini CLI":
            return "支持 Gemini CLI 配对连接"
        default:
            return "支持加密连接链接"
        }
    }

    var body: some View {
        ZStack {
            // Camera preview
            QRCameraPreview(session: scannerDelegate.captureSession)
                .ignoresSafeArea()

            // Overlay
            VStack {
                // Top bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }

                    Spacer()

                    Text("扫描二维码")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    // Photo library button
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Image(systemName: "photo.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                }
                .padding()
                .background(.ultraThinMaterial)

                Spacer()

                // Scanning frame
                ZStack {
                    // Corner brackets
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.5), lineWidth: 2)
                        .frame(width: 280, height: 280)

                    // Animated scanning line
                    if isScanning {
                        ScanningLine()
                    }

                    // Corner decorations
                    VStack {
                        HStack {
                            CornerBracket(position: .topLeft)
                            Spacer()
                            CornerBracket(position: .topRight)
                        }
                        Spacer()
                        HStack {
                            CornerBracket(position: .bottomLeft)
                            Spacer()
                            CornerBracket(position: .bottomRight)
                        }
                    }
                    .frame(width: 280, height: 280)
                }

                Spacer()

                // Instructions
                VStack(spacing: 12) {
                    Text("将二维码放入框内")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(hintText)  // 根据 Agent Type 显示不同提示
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))

                    // Manual input button
                    Button {
                        showManualInput = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 14))
                            Text("手动输入地址")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .padding(.top, 8)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear {
            scannerDelegate.startScanning()
            scannerDelegate.onCodeScanned = { code in
                print("[QRScanner] ✅ QR Code scanned")
                scannedURL = code
                dismiss()
            }
            scannerDelegate.onError = { error in
                print("[QRScanner] ❌ Error: \(error)")
                errorMessage = error
                showError = true
            }
        }
        .onDisappear {
            scannerDelegate.stopScanning()
        }
        .onChange(of: selectedImage) { _, newImage in
            guard let image = newImage else { return }

            // Detect QR code from selected image
            if let qrCode = QRCodeDetector.detectQRCode(from: image) {
                print("[QRScanner] ✅ QR Code detected from image")

                // Haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)

                scannedURL = qrCode
                dismiss()
            } else {
                print("[QRScanner] ❌ No QR code found in image")
                errorMessage = "未能从图片中识别二维码，请选择包含二维码的图片"
                showError = true
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(selectedImage: $selectedImage)
        }
        .sheet(isPresented: $showManualInput) {
            ManualURLInputView(
                url: $manualURL,
                onConfirm: { url in
                    if isValidWebSocketURL(url) {
                        // Haptic feedback
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)

                        scannedURL = url
                        showManualInput = false
                        dismiss()
                    } else {
                        errorMessage = "请输入有效的 WebSocket 地址 (ws:// 或 wss://)"
                        showError = true
                        showManualInput = false
                    }
                }
            )
        }
        .alert("扫描错误", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Helper Methods

    private func isValidWebSocketURL(_ url: String) -> Bool {
        return url.hasPrefix("ws://") || url.hasPrefix("wss://")
    }
}

// MARK: - Camera Preview

struct QRCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}
}

class CameraPreviewView: UIView {
    var session: AVCaptureSession? {
        didSet {
            guard let session = session else { return }

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.frame = bounds
            previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(previewLayer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.first?.frame = bounds
    }
}

// MARK: - Scanner Delegate

class QRScannerDelegate: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    let captureSession = AVCaptureSession()
    var onCodeScanned: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var hasScanned = false

    func startScanning() {
        // Check camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.setupCaptureSession()
                    }
                } else {
                    self?.onError?("需要相机权限才能扫描二维码")
                }
            }
        case .denied, .restricted:
            onError?("请在设置中允许相机权限")
        @unknown default:
            onError?("相机权限状态未知")
        }
    }

    private func setupCaptureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?("无法访问相机")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)

            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }

            let output = AVCaptureMetadataOutput()

            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                output.metadataObjectTypes = [.qr]
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession.startRunning()
            }

        } catch {
            onError?("相机设置失败: \(error.localizedDescription)")
        }
    }

    func stopScanning() {
        captureSession.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else {
            return
        }

        hasScanned = true

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Call callback
        onCodeScanned?(stringValue)
    }
}

// MARK: - UI Components

struct ScanningLine: View {
    @State private var offset: CGFloat = -140

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0),
                        Color.blue.opacity(0.8),
                        Color.blue.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 2)
            .frame(width: 280)
            .offset(y: offset)
            .onAppear {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: true)) {
                    offset = 140
                }
            }
    }
}

enum CornerPosition {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct CornerBracket: View {
    let position: CornerPosition
    let size: CGFloat = 30
    let thickness: CGFloat = 4

    var body: some View {
        ZStack {
            switch position {
            case .topLeft:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: size, height: thickness)
                        Spacer()
                    }
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: thickness, height: size)
                        Spacer()
                    }
                    Spacer()
                }
            case .topRight:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer()
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: size, height: thickness)
                    }
                    HStack(spacing: 0) {
                        Spacer()
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: thickness, height: size)
                    }
                    Spacer()
                }
            case .bottomLeft:
                VStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: thickness, height: size)
                        Spacer()
                    }
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: size, height: thickness)
                        Spacer()
                    }
                }
            case .bottomRight:
                VStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 0) {
                        Spacer()
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: thickness, height: size)
                    }
                    HStack(spacing: 0) {
                        Spacer()
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: size, height: thickness)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Manual URL Input View

struct ManualURLInputView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var url: String
    let onConfirm: (String) -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("输入服务器地址")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("请输入完整的 WebSocket 地址")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    TextField("ws://127.0.0.1:18789", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                } header: {
                    Text("WebSocket 地址")
                } footer: {
                    Text("支持 ws:// 或 wss:// 协议")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    VStack(spacing: 12) {
                        Text("示例地址:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                url = "ws://127.0.0.1:18789"
                            } label: {
                                HStack {
                                    Text("ws://127.0.0.1:18789")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.blue)
                                    Spacer()
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Button {
                                url = "wss://gateway.example.com"
                            } label: {
                                HStack {
                                    Text("wss://gateway.example.com")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.blue)
                                    Spacer()
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("快速填充")
                }
            }
            .navigationTitle("手动输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("确定") {
                        onConfirm(url)
                    }
                    .disabled(url.isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                isTextFieldFocused = true
            }
        }
    }
}

#Preview {
    QRCodeScannerView(scannedURL: .constant(nil))
}
