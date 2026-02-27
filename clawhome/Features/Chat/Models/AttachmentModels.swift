//
//  AttachmentModels.swift
//  contextgo
//
//  Attachment data models for file upload
//

import Foundation

// AttachmentType is defined in ChatInputModels.swift

// MARK: - Attachment Item

struct AttachmentItem: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let fileData: Data
    let mimeType: String
    let type: AttachmentType

    // Upload state (optional, populated after upload)
    var uploadResult: AttachmentUploadResult?
    var isUploading: Bool = false
    var uploadError: String?

    var fileSize: Int64 {
        return Int64(fileData.count)
    }

    var fileSizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    static func == (lhs: AttachmentItem, rhs: AttachmentItem) -> Bool {
        return lhs.id == rhs.id
    }
}
