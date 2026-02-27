//
//  AttachmentService.swift
//  contextgo
//
//

import Foundation
import CryptoKit

@MainActor
class AttachmentService: ObservableObject {
    static let shared = AttachmentService()

    @Published var isUploading = false
    @Published var uploadProgress: Double = 0.0

    private let coreClient = CoreAPIClient.shared
    private let fileManager = FileManager.default
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private static let archiveDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
    private static let archiveTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HHmmssSSS"
        return formatter
    }()

    private init() {
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    // MARK: - Upload Flow

    func uploadFile(fileData: Data, fileName: String, mimeType: String?, sessionId: String? = nil) async throws -> AttachmentUploadResult {
        guard !fileData.isEmpty else {
            throw AttachmentError.emptyFile
        }

        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unnamed" : fileName
        let normalizedMimeType = (mimeType?.isEmpty == false) ? mimeType! : "application/octet-stream"

        isUploading = true
        uploadProgress = 0.05
        defer {
            isUploading = false
            uploadProgress = 0.0
        }

        let preferredLocalUserId = resolvePreferredLocalUserId()
        let archivedLocalURL = try persistLocalArchive(
            fileData: fileData,
            fileName: normalizedFileName,
            userId: preferredLocalUserId
        )
        let archivedData = try Data(contentsOf: archivedLocalURL)
        uploadProgress = 0.2

        let uploadInfo = try await coreClient.uploadAttachment(
            data: archivedData,
            fileName: normalizedFileName,
            mimeType: normalizedMimeType
        )
        uploadProgress = 0.65

        let urlData: CoreAttachmentURLData
        do {
            urlData = try await coreClient.getAttachmentURL(attachmentUri: uploadInfo.attachmentUri)
        } catch {
            let encodedURI = uploadInfo.attachmentUri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadInfo.attachmentUri
            urlData = CoreAttachmentURLData(
                url: "/api/attachments/download?attachmentUri=\(encodedURI)",
                etag: nil,
                sha256: uploadInfo.hash,
                md5: uploadInfo.md5
            )
        }
        uploadProgress = 0.8

        let localUserId = resolveLocalUserId(from: uploadInfo, fallbackUserId: preferredLocalUserId)
        try persistLocalMirror(
            uploadInfo: uploadInfo,
            fileData: archivedData,
            userId: localUserId
        )
        await emitAttachmentUploadedEvent(
            uploadInfo: uploadInfo,
            userId: localUserId,
            sessionId: sessionId
        )
        uploadProgress = 1.0

        return AttachmentUploadResult(
            attachmentId: uploadInfo.id,
            attachmentUri: uploadInfo.attachmentUri,
            storageUri: uploadInfo.storageUri,
            sha256: uploadInfo.hash,
            md5: uploadInfo.md5,
            downloadUrl: urlData.url,
            expiresAt: "",
            fileName: uploadInfo.fileName,
            fileSize: uploadInfo.sizeBytes,
            mimeType: uploadInfo.mimeType,
            messageProtocol: buildMessageProtocol(
                attachmentUri: uploadInfo.attachmentUri,
                fileName: uploadInfo.fileName,
                mimeType: uploadInfo.mimeType
            )
        )
    }

    private func resolvePreferredLocalUserId() -> String {
        if let authUserId = AuthService.shared.currentUser?.id, !authUserId.isEmpty {
            return authUserId
        }
        return SessionStorageLayout.defaultLocalUserId
    }

    private func resolveLocalUserId(from info: CoreAttachmentInfo, fallbackUserId: String) -> String {
        if let userId = info.userId, !userId.isEmpty {
            return userId
        }
        if let parsed = SessionStorageLayout.parseAttachmentResourceURI(info.attachmentUri), !parsed.userId.isEmpty {
            return parsed.userId
        }
        return fallbackUserId
    }

    private func sanitizeArchiveFileName(_ fileName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let sanitizedScalars = fileName.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(sanitizedScalars)
        return sanitized.isEmpty ? "unnamed" : sanitized
    }

    private func persistLocalArchive(fileData: Data, fileName: String, userId: String) throws -> URL {
        let now = Date()
        let dayKey = Self.archiveDayFormatter.string(from: now)
        let timestamp = Self.archiveTimeFormatter.string(from: now)
        let safeName = sanitizeArchiveFileName(fileName)
        let archiveName = "\(timestamp)_\(UUID().uuidString.prefix(8))_\(safeName)"

        let archiveDirectory = sessionsStorageRootURL()
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(SessionStorageLayout.encodePathComponent(userId), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(dayKey, isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)

        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        let archiveURL = archiveDirectory.appendingPathComponent(archiveName)
        try fileData.write(to: archiveURL, options: .atomic)
        return archiveURL
    }

    private func persistLocalMirror(uploadInfo: CoreAttachmentInfo, fileData: Data, userId: String) throws {
        guard let parsed = SessionStorageLayout.parseAttachmentResourceURI(uploadInfo.attachmentUri) else {
            throw AttachmentError.invalidAttachmentURI(uploadInfo.attachmentUri)
        }
        let attachmentId = parsed.attachmentId
        guard let dateKey = SessionStorageLayout.attachmentDateKey(
            attachmentId: attachmentId,
            createdAt: uploadInfo.createdAt
        ) else {
            throw AttachmentError.invalidAttachmentURI("missing date partition in attachmentId: \(attachmentId)")
        }
        let sessionsRoot = sessionsStorageRootURL()

        let objectURL = SessionStorageLayout.attachmentObjectFileURL(
            baseDirectory: sessionsRoot,
            userId: userId,
            sha256: uploadInfo.hash,
            dateKey: dateKey
        )
        let metaURL = SessionStorageLayout.attachmentMetaFileURL(
            baseDirectory: sessionsRoot,
            userId: userId,
            attachmentId: attachmentId,
            dateKey: dateKey
        )

        try fileManager.createDirectory(at: objectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if shouldWriteObject(to: objectURL, sha256: uploadInfo.hash) {
            try fileData.write(to: objectURL, options: .atomic)
        }

        let relativeObjectPath = SessionStorageLayout.attachmentObjectRelativePath(
            userId: userId,
            sha256: uploadInfo.hash,
            dateKey: dateKey
        )
        let record = LocalAttachmentMetaRecord(
            id: attachmentId,
            userId: userId,
            datePath: dateKey,
            fileName: uploadInfo.fileName,
            mimeType: uploadInfo.mimeType,
            sizeBytes: uploadInfo.sizeBytes,
            sha256: uploadInfo.hash,
            md5: uploadInfo.md5,
            objectPath: relativeObjectPath,
            attachmentUri: uploadInfo.attachmentUri,
            createdAt: uploadInfo.createdAt,
            source: .init(
                etag: nil,
                mtime: uploadInfo.createdAt,
                size: uploadInfo.sizeBytes
            )
        )

        if !shouldWriteMeta(to: metaURL, incoming: record) {
            return
        }

        let data = try jsonEncoder.encode(record)
        try data.write(to: metaURL, options: .atomic)
    }

    private func shouldWriteObject(to url: URL, sha256: String) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return true
        }
        guard let existingData = try? Data(contentsOf: url) else {
            return true
        }
        let existingHash = sha256Hex(for: existingData)
        return existingHash != sha256
    }

    private func shouldWriteMeta(to url: URL, incoming: LocalAttachmentMetaRecord) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return true
        }
        guard let existingData = try? Data(contentsOf: url),
              let existing = try? jsonDecoder.decode(LocalAttachmentMetaRecord.self, from: existingData) else {
            return true
        }
        return existing.sha256 != incoming.sha256 || existing.fileName != incoming.fileName || existing.sizeBytes != incoming.sizeBytes
    }

    private func sessionsStorageRootURL() -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("sessions", isDirectory: true)
        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func sha256Hex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func buildMessageProtocol(attachmentUri: String, fileName: String, mimeType: String) -> String {
        "[ctxgo-attachment]\(attachmentUri)|\(fileName)|\(mimeType)"
    }

    private func emitAttachmentUploadedEvent(
        uploadInfo: CoreAttachmentInfo,
        userId: String,
        sessionId: String?
    ) async {
        var payload: [String: AnyCodable] = [
            "attachmentId": AnyCodable(uploadInfo.id),
            "attachmentUri": AnyCodable(uploadInfo.attachmentUri),
            "storageUri": AnyCodable(uploadInfo.storageUri),
            "fileName": AnyCodable(uploadInfo.fileName),
            "mimeType": AnyCodable(uploadInfo.mimeType),
            "sizeBytes": AnyCodable(uploadInfo.sizeBytes),
            "sha256": AnyCodable(uploadInfo.hash),
            "md5": AnyCodable(uploadInfo.md5),
            "createdAt": AnyCodable(uploadInfo.createdAt),
            "userId": AnyCodable(userId),
        ]

        if let sessionId, !sessionId.isEmpty {
            payload["sessionId"] = AnyCodable(sessionId)
        }

        do {
            _ = try await coreClient.appendEvent(
                event: CgoEventInput(
                    eventId: nil,
                    scope: .system(key: "attachments"),
                    provider: .contextgoIOS,
                    source: .iosAttachmentUpload,
                    type: .attachmentUploaded,
                    timestamp: nil,
                    payload: payload
                )
            )
        } catch {
            // Best-effort auditing: upload should not fail if event reporting fails.
            print("⚠️ [AttachmentService] Failed to emit attachment.uploaded event: \(error)")
        }
    }
}

// MARK: - Result Model

struct AttachmentUploadResult {
    let attachmentId: String
    let attachmentUri: String
    let storageUri: String
    let sha256: String
    let md5: String
    let downloadUrl: String
    let expiresAt: String
    let fileName: String
    let fileSize: Int
    let mimeType: String
    let messageProtocol: String
}

// MARK: - Errors

enum AttachmentError: LocalizedError {
    case emptyFile
    case invalidAttachmentURI(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "附件内容为空"
        case .invalidAttachmentURI(let uri):
            return "附件 URI 非法: \(uri)"
        }
    }
}

private struct LocalAttachmentMetaRecord: Codable {
    struct Source: Codable {
        let etag: String?
        let mtime: String
        let size: Int
    }

    let id: String
    let userId: String
    let datePath: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let sha256: String
    let md5: String
    let objectPath: String
    let attachmentUri: String
    let createdAt: String
    let source: Source
}
