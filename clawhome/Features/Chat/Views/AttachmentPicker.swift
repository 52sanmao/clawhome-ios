//
//  AttachmentPicker.swift
//  contextgo
//
//  Attachment picker panel (embedded below input bar)
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Embedded Attachment Picker Panel

struct AttachmentPickerPanel: View {
    @Binding var selectedAttachments: [AttachmentItem]
    var onDismiss: () -> Void
    var onMeetingRecording: (() -> Void)?  // New: callback for meeting recording

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showDocumentPicker = false
    @State private var documentPickerErrorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("添加附件")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Text("支持照片、文件与录音纪要")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 10,
                    matching: .any(of: [.images, .videos])
                ) {
                    AttachmentOptionCard(
                        icon: "photo.on.rectangle.angled",
                        title: "照片/视频",
                        subtitle: "图库与视频",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                .onChange(of: selectedPhotoItems) { _, newItems in
                    Task {
                        await loadPhotoItems(newItems)
                        onDismiss()
                    }
                }

                Button(action: {
                    showDocumentPicker = true
                }) {
                    AttachmentOptionCard(
                        icon: "doc.fill",
                        title: "文件",
                        subtitle: "PDF/音频等",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)

                Button(action: {
                    onMeetingRecording?()
                    onDismiss()
                }) {
                    AttachmentOptionCard(
                        icon: "mic.circle.fill",
                        title: "录音纪要",
                        subtitle: "会议转写",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView(
                selectedAttachments: $selectedAttachments,
                onError: { message in
                    documentPickerErrorMessage = message
                }
            )
                .onDisappear {
                    if !selectedAttachments.isEmpty {
                        onDismiss()
                    }
                }
        }
        .alert("文件读取失败", isPresented: Binding(
            get: { documentPickerErrorMessage != nil },
            set: { show in
                if !show {
                    documentPickerErrorMessage = nil
                }
            }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(documentPickerErrorMessage ?? "请重试")
        }
    }

    private func loadPhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            // Load image data
            if let data = try? await item.loadTransferable(type: Data.self) {
                let fileName = item.itemIdentifier ?? "photo_\(Date().timeIntervalSince1970).jpg"
                let mimeType = determineMimeType(from: data)
                let type: AttachmentType = mimeType.starts(with: "video/") ? .video : .image

                let attachment = AttachmentItem(
                    fileName: fileName,
                    fileData: data,
                    mimeType: mimeType,
                    type: type
                )
                selectedAttachments.append(attachment)
            }
        }
    }

    private func determineMimeType(from data: Data) -> String {
        var byte: UInt8 = 0
        data.copyBytes(to: &byte, count: 1)

        switch byte {
        case 0xFF: return "image/jpeg"
        case 0x89: return "image/png"
        case 0x47: return "image/gif"
        case 0x00: return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}

private struct AttachmentOptionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(tint)
            }

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
        )
    }
}

// MARK: - Legacy Sheet Wrapper (for backward compatibility)

struct AttachmentPicker: View {
    @Binding var selectedAttachments: [AttachmentItem]
    var onMeetingRecording: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AttachmentPickerPanel(
            selectedAttachments: $selectedAttachments,
            onDismiss: { dismiss() },
            onMeetingRecording: onMeetingRecording
        )
        .presentationDetents([.height(120)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    @Binding var selectedAttachments: [AttachmentItem]
    @Environment(\.dismiss) private var dismiss
    var onError: ((String) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.pdf, .text, .audio, .movie, .data],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView

        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            var successfulCount = 0
            var latestErrorMessage: String?

            for url in urls {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                if !didStartAccessing {
                    print("⚠️ [DocumentPicker] startAccessingSecurityScopedResource returned false: \(url.lastPathComponent)")
                }
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let data = try loadFileData(from: url)
                    let fileName = url.lastPathComponent
                    let mimeType = url.mimeType()
                    let type: AttachmentType = {
                        if mimeType.starts(with: "audio/") { return .audio }
                        if mimeType.starts(with: "video/") { return .video }
                        if mimeType.starts(with: "image/") { return .image }
                        return .file
                    }()

                    let attachment = AttachmentItem(
                        fileName: fileName,
                        fileData: data,
                        mimeType: mimeType,
                        type: type
                    )
                    DispatchQueue.main.async {
                        self.parent.selectedAttachments.append(attachment)
                    }
                    successfulCount += 1
                } catch {
                    latestErrorMessage = "无法读取文件：\(url.lastPathComponent)。请在“文件”App中确认该文件已下载后重试"
                    print("❌ [DocumentPicker] Failed to load file \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if successfulCount == 0, let latestErrorMessage {
                DispatchQueue.main.async {
                    self.parent.onError?(latestErrorMessage)
                }
            }

            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }

        private func loadFileData(from url: URL) throws -> Data {
            do {
                return try Data(contentsOf: url)
            } catch {
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinatedError: NSError?
                var coordinatedData: Data?
                var readError: Error?
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatedError) { coordinatedURL in
                    do {
                        coordinatedData = try Data(contentsOf: coordinatedURL)
                    } catch {
                        readError = error
                    }
                }

                if let coordinatedData {
                    return coordinatedData
                }

                let fileManager = FileManager.default
                let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("contextgo-picked-files", isDirectory: true)
                try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

                let tempFileURL = tempDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                if fileManager.fileExists(atPath: tempFileURL.path) {
                    try fileManager.removeItem(at: tempFileURL)
                }

                try fileManager.copyItem(at: url, to: tempFileURL)
                defer {
                    try? fileManager.removeItem(at: tempFileURL)
                }

                do {
                    return try Data(contentsOf: tempFileURL)
                } catch {
                    if let readError {
                        throw readError
                    }
                    if let coordinatedError {
                        throw coordinatedError
                    }
                    throw error
                }
            }
        }
    }
}

// MARK: - URL Extension

extension URL {
    func mimeType() -> String {
        if let typeID = try? resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
           let utType = UTType(typeID) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
