import Foundation

@MainActor
class ContextService: ObservableObject {
    static let shared = ContextService()

    @Published var isProcessing = false

    private let coreClient = CoreAPIClient.shared
    private var contextCache: [String: ContextMetadata] = [:]
    private var contentCache: [String: String] = [:]

    private let isoFormatter = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {}

    func listContexts(spaceId: String? = nil, status: String? = nil) async throws -> [ContextMetadata] {
        let normalizedStatus = normalizeStatus(status)

        let spaceIds: [String]
        if let spaceId {
            spaceIds = [spaceId]
        } else {
            spaceIds = try await coreClient.listSpaces().map { $0.id }
        }

        var merged: [String: ContextMetadata] = [:]
        for id in spaceIds {
            let contexts = try await fetchCoreContexts(spaceId: id, status: normalizedStatus)
            for context in contexts {
                merged[context.id] = context
            }
        }

        var result = Array(merged.values)
        if let normalizedStatus {
            result = result.filter { $0.status == normalizedStatus }
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    func getContext(contextId: String) async throws -> ContextMetadata {
        if let cached = contextCache[contextId] {
            return cached
        }

        let contexts = try await listContexts()
        if let context = contexts.first(where: { $0.id == contextId }) {
            return context
        }

        throw ContextError.notFound
    }

    func createContext(
        spaceId: String,
        title: String,
        content: String? = nil,
        description: String? = nil,
        tags: [String]? = nil,
        buildingSource: String? = nil,
        buildingSourceId: String? = nil,
        attachmentUris: [String]? = nil
    ) async throws -> ContextMetadata {
        let day = todayString()
        let ctxUri = coreClient.makeContextUri(spaceId: spaceId)
        let finalContent = mergeContent(
            content: content,
            description: description,
            tags: tags,
            buildingSource: buildingSource,
            buildingSourceId: buildingSourceId
        )
        let entryId = try await coreClient.createContext(
            ctxUri: ctxUri,
            intent: title,
            result: finalContent,
            relations: CoreContextRelations(
                tasks: nil,
                attachments: attachmentUris,
                skills: nil,
                contexts: nil
            ),
            meta: CoreContextEntryMeta(
                contextKind: "atomic.manual_build",
                status: "pending",
                importanceScore: attachmentUris?.isEmpty == false ? 65 : 55,
                importanceReason: "iOS Build 提交",
                sourceEventId: nil
            )
        )

        let now = nowISO()
        let metadata = ContextMetadata(
            id: entryId,
            userId: nil,
            spaceId: spaceId,
            title: title,
            description: description,
            tags: encodeTags(tags),
            ossPath: "",
            status: "pending",
            archivedAt: nil,
            pendingAIUpdate: false,
            syncStatus: "synced",
            lastSyncAt: now,
            version: 1,
            viewCount: 0,
            aiUsageCount: 0,
            createdAt: now,
            updatedAt: now,
            buildingSource: nil,
            buildingSourceId: nil,
            buildingProgress: nil,
            buildingError: nil,
            buildingStartedAt: nil,
            ctxUri: ctxUri,
            day: day,
            contextKind: "atomic.manual_build",
            importanceScore: attachmentUris?.isEmpty == false ? 65 : 55,
            importanceReason: "iOS Build 提交",
            entryUri: nil,
            sourceEventId: nil
        )

        contextCache[entryId] = metadata
        contentCache[entryId] = finalContent
        return metadata
    }

    func downloadContent(contextId: String) async throws -> String {
        if let cached = contentCache[contextId] {
            return cached
        }

        if let entry = try? await coreClient.getContextEntry(entryId: contextId) {
            let content = makeMarkdown(intent: entry.intent, result: entry.result)
            contentCache[contextId] = content
            return content
        }

        let context = try await getContext(contextId: contextId)
        let ctxUri: String
        if let cachedUri = context.ctxUri {
            ctxUri = cachedUri
        } else {
            ctxUri = coreClient.makeContextUri(spaceId: context.spaceId)
        }
        let content = try await coreClient.readContext(ctxUri: ctxUri)
        contentCache[contextId] = content
        return content
    }

    func fetchSummary() async throws -> StatsSummary {
        let contexts = try await listContexts(status: "pending")
        let today = todayString()

        return StatsSummary(
            totalCount: contexts.count,
            draftCount: contexts.count,
            archivedCount: 0,
            buildingCount: 0,
            todayCount: contexts.filter { $0.createdAt.hasPrefix(today) }.count
        )
    }

    func updateContextStatus(contextId: String, status: String) async throws {
        let normalizedStatus = normalizeStatus(status) ?? status
        let success = try await coreClient.updateContextEntryStatus(entryId: contextId, status: normalizedStatus)
        guard success else {
            throw ContextError.syncFailed
        }

        if let cached = contextCache[contextId] {
            var updated = cached
            updated.status = normalizedStatus
            updated.updatedAt = nowISO()
            contextCache[contextId] = updated
        }
    }

    func emitMeetingNotesUploadedEvent(
        spaceId: String,
        audioAttachmentUri: String,
        transcriptAttachmentUri: String,
        titleHint: String? = nil,
        source: CoreSessionEventSource = .iosContextBuildMeetingRecording,
        provider: CoreSessionEventProvider = .contextgoCore
    ) async throws -> CgoEvent {
        var payload: [String: AnyCodable] = [
            "spaceId": AnyCodable(spaceId),
            "audioAttachmentUri": AnyCodable(audioAttachmentUri),
            "transcriptAttachmentUri": AnyCodable(transcriptAttachmentUri)
        ]
        if let titleHint, !titleHint.isEmpty {
            payload["titleHint"] = AnyCodable(titleHint)
        }

        return try await coreClient.appendEvent(
            event: CgoEventInput(
                eventId: nil,
                scope: .space(spaceId: spaceId),
                provider: provider,
                source: source,
                type: .meetingNotesUploaded,
                timestamp: nil,
                payload: payload
            )
        )
    }

    private func fetchCoreContexts(spaceId: String, status: String?) async throws -> [ContextMetadata] {
        let today = todayString()
        let fromDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let results = try await searchContextsBySpaceURI(
            spaceId: spaceId,
            status: status,
            fromDate: fromDate,
            toDay: today
        )
        return mapSearchResults(results)
    }

    private func mapSearchResults(_ results: [CoreContextSearchResult]) -> [ContextMetadata] {
        var mapped: [ContextMetadata] = []
        mapped.reserveCapacity(results.count)

        for item in results {
            let createdAt = "\(item.date)T00:00:00.000Z"
            let ctxUri = coreClient.makeContextUri(spaceId: item.spaceId)
            let metadata = ContextMetadata(
                id: item.id,
                userId: nil,
                spaceId: item.spaceId,
                title: makeTitle(item.intent),
                description: makeDescription(item.result),
                tags: nil,
                ossPath: "",
                status: item.status ?? "pending",
                archivedAt: nil,
                pendingAIUpdate: false,
                syncStatus: "synced",
                lastSyncAt: createdAt,
                version: 1,
                viewCount: 0,
                aiUsageCount: 0,
                createdAt: createdAt,
                updatedAt: createdAt,
                buildingSource: nil,
                buildingSourceId: nil,
                buildingProgress: nil,
                buildingError: nil,
                buildingStartedAt: nil,
                ctxUri: ctxUri,
                day: item.date,
                contextKind: item.kind,
                importanceScore: item.importanceScore,
                importanceReason: item.importanceReason,
                entryUri: item.entryUri,
                sourceEventId: item.sourceEventId
            )

            contextCache[item.id] = metadata
            contentCache[item.id] = makeMarkdown(intent: item.intent, result: item.result)
            mapped.append(metadata)
        }

        return mapped
    }

    private func searchContextsBySpaceURI(
        spaceId: String,
        status: String?,
        fromDate: Date,
        toDay: String
    ) async throws -> [CoreContextSearchResult] {
        let from = Self.dayFormatter.string(from: fromDate)
        let requestURI = coreClient.makeContextUri(spaceId: spaceId)
        return try await coreClient.searchContexts(
            ctxUri: requestURI,
            kinds: ["atomic.meeting_notes", "atomic.manual_build", "atomic.event_derived"],
            statuses: status != nil ? [status!] : nil,
            dateRange: [from, toDay],
            limit: 500
        )
    }

    private func mergeContent(
        content: String?,
        description: String?,
        tags: [String]?,
        buildingSource: String?,
        buildingSourceId: String?
    ) -> String {
        var segments: [String] = []

        if let content, !content.isEmpty {
            segments.append(content)
        }
        if let description, !description.isEmpty {
            segments.append("Description: \(description)")
        }
        if let tags, !tags.isEmpty {
            segments.append("Tags: \(tags.joined(separator: ", "))")
        }
        if let buildingSource, !buildingSource.isEmpty {
            segments.append("Source: \(buildingSource)")
        }
        if let buildingSourceId, !buildingSourceId.isEmpty {
            segments.append("SourceId: \(buildingSourceId)")
        }

        if segments.isEmpty {
            return "(empty)"
        }

        return segments.joined(separator: "\n\n")
    }

    private func makeTitle(_ intent: String) -> String {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Context" : String(trimmed.prefix(80))
    }

    private func makeDescription(_ result: String) -> String {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(120))
    }

    private func makeMarkdown(intent: String, result: String) -> String {
        return "# \(intent)\n\n\(result)"
    }

    private func normalizeStatus(_ status: String?) -> String? {
        guard let status else { return nil }
        switch status {
        case "draft":
            return "pending"
        default:
            return status
        }
    }

    private func encodeTags(_ tags: [String]?) -> String? {
        guard let tags, !tags.isEmpty else {
            return nil
        }
        guard let data = try? JSONEncoder().encode(tags) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func todayString() -> String {
        Self.dayFormatter.string(from: Date())
    }

    private func nowISO() -> String {
        isoFormatter.string(from: Date())
    }
}

struct StatsSummary: Decodable {
    let totalCount: Int
    let draftCount: Int
    let archivedCount: Int
    let buildingCount: Int
    let todayCount: Int
}

struct ContextMetadata: Identifiable, Hashable {
    let id: String
    let userId: String?
    let spaceId: String
    var title: String
    var description: String?
    var tags: String?
    var ossPath: String
    var status: String
    var archivedAt: String?
    var pendingAIUpdate: Bool
    var syncStatus: String
    var lastSyncAt: String?
    var version: Int
    var viewCount: Int
    var aiUsageCount: Int
    var createdAt: String
    var updatedAt: String
    var buildingSource: String?
    var buildingSourceId: String?
    var buildingProgress: Int?
    var buildingError: String?
    var buildingStartedAt: String?
    var ctxUri: String?
    var day: String
    var contextKind: String? = nil
    var importanceScore: Int? = nil
    var importanceReason: String? = nil
    var entryUri: String? = nil
    var sourceEventId: String? = nil

    var tagsArray: [String] {
        guard let tags,
              let data = tags.data(using: .utf8),
              let value = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return value
    }
}

enum ContextError: LocalizedError {
    case invalidContent
    case invalidOSSURL
    case ossUploadFailed
    case ossDownloadFailed
    case syncFailed
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidContent:
            return "无效的内容格式"
        case .invalidOSSURL:
            return "无效的 OSS URL"
        case .ossUploadFailed:
            return "上传到 OSS 失败"
        case .ossDownloadFailed:
            return "从 OSS 下载失败"
        case .syncFailed:
            return "同步失败"
        case .notFound:
            return "Context 不存在"
        }
    }
}
