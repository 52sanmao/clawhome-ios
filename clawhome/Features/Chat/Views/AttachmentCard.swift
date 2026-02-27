//
//  AttachmentCard.swift
//  contextgo
//
//  Preview card for selected attachments (支持所有文件类型)
//

import SwiftUI

struct AttachmentCard: View {
    let attachment: AttachmentItem
    let onRemove: () -> Void
    var showsRemoveButton: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Icon or thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colorScheme == .dark ? Color(uiColor: .systemGray5) : Color(uiColor: .systemGray6))
                        .frame(width: 60, height: 60)

                    // Show image preview or file type icon
                    if attachment.type == .image, let uiImage = UIImage(data: attachment.fileData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(spacing: 4) {
                            // File type icon
                            Image(systemName: attachment.type.icon)
                                .font(.system(size: 24))
                                .foregroundColor(iconColor(for: attachment.type))

                            // File extension label
                            if let ext = fileExtension(from: attachment.fileName) {
                                Text(ext.uppercased())
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Upload status indicator
                    if attachment.isUploading {
                        ZStack {
                            Color.black.opacity(0.5)
                            ProgressView()
                                .tint(.white)
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if attachment.uploadError != nil {
                        // Error indicator
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                        }
                    } else if attachment.uploadResult != nil {
                        // Success indicator
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Color.green)
                                    .clipShape(Circle())
                            }
                        }
                    }
                }

                // Remove button
                if showsRemoveButton {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .offset(x: 5, y: -5)
                }
            }

            // File info
            VStack(spacing: 2) {
                Text(attachment.fileName)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 60)

                Text(attachment.fileSizeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 70)
    }

    // MARK: - Helpers

    private func iconColor(for type: AttachmentType) -> Color {
        switch type {
        case .image:
            return .blue
        case .video:
            return .purple
        case .audio:
            return .green
        case .file:
            return .orange
        }
    }

    private func fileExtension(from fileName: String) -> String? {
        let components = fileName.split(separator: ".")
        guard components.count > 1 else { return nil }
        return String(components.last ?? "")
    }
}
