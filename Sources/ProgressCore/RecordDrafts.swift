import Foundation

public struct DraftRecurrence: Codable, Equatable, Sendable {
    public var seriesID: UUID
    public var occurrence: Date
    public var scope: String
    public init(seriesID: UUID, occurrence: Date, scope: RecurrenceScope) {
        self.seriesID = seriesID; self.occurrence = occurrence; self.scope = scope.rawValue
    }
}

public struct RecordDraft: Codable, Identifiable, Equatable, Sendable {
    public var record: WorkRecord
    public var original: WorkRecord?
    public var recurrence: DraftRecurrence?
    public var updatedAt: Date
    public var sourceKey: String?
    public var taskScope: RecurrenceScope?
    public var id: String { sourceKey ?? Self.key(record.id, recurrence: recurrence) }
    public static func key(_ id: UUID, recurrence: DraftRecurrence? = nil) -> String {
        guard let recurrence else { return id.uuidString }
        return "\(id)-\(recurrence.scope)-\(recurrence.scope == RecurrenceScope.series.rawValue ? 0 : floor(recurrence.occurrence.timeIntervalSinceReferenceDate))"
    }
    public init(record: WorkRecord, original: WorkRecord?, recurrence: DraftRecurrence? = nil, updatedAt: Date = Date(), sourceKey: String? = nil, taskScope: RecurrenceScope? = nil) {
        self.record = record; self.original = original; self.recurrence = recurrence; self.updatedAt = updatedAt; self.sourceKey = sourceKey; self.taskScope = taskScope
    }
    public func conflicts(in workspace: Workspace) -> Bool {
        !Self.samePersisted(workspace.record(original?.id ?? record.id), original)
    }
    public func recurrenceForRecovery(in workspace: Workspace) -> DraftRecurrence? {
        guard var value = recurrence else { return nil }
        if let actual = workspace.reminderDestination(for: ReminderNotificationTarget(recordID: value.seriesID, occurrence: value.occurrence))?.occurrence {
            value.occurrence = actual
        }
        return value
    }
    private static func samePersisted(_ lhs: WorkRecord?, _ rhs: WorkRecord?) -> Bool {
        // Workspace snapshots store ISO dates at whole-second precision.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        guard let a = try? encoder.encode(lhs), let b = try? encoder.encode(rhs) else { return false }
        return a == b
    }
    public func alreadySaved(in workspace: Workspace) -> Bool {
        guard recurrence == nil, let saved = workspace.record(record.id) else { return false }
        var candidate = record; candidate.updatedAt = saved.updatedAt
        if candidate.status == .completed && candidate.completedAt == nil { candidate.completedAt = saved.completedAt }
        return Self.samePersisted(candidate, saved)
    }
}

/// Drafts are stored separately from committed workspace data and included in migration backups.
/// Rewriting an empty collection clears a draft without deleting files.
public struct RecordDraftRepository {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [RecordDraft] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 1 else { throw WorkspaceError("草稿格式暂不支持，原文件已保留。") }
        guard Set(envelope.drafts.map(\.id)).count == envelope.drafts.count,
              envelope.drafts.allSatisfy({ $0.recurrence.map { RecurrenceScope(rawValue: $0.scope) != nil } ?? true }) else {
            throw WorkspaceError("草稿文件不完整，原文件已保留。")
        }
        return envelope.drafts
    }
    public func save(_ drafts: [RecordDraft]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Envelope(version: 1, drafts: drafts))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private struct Envelope: Codable { var version: Int; var drafts: [RecordDraft] }
}
