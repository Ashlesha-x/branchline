import Foundation

public struct MigrationBackup: Sendable, Equatable {
    public var workspace: Workspace
    public var drafts: [RecordDraft]
    public var review: ReviewDraft?
    public var includesReview: Bool
    public var includesDrafts: Bool
    public init(workspace: Workspace, drafts: [RecordDraft], includesDrafts: Bool = true, review: ReviewDraft? = nil, includesReview: Bool = true) {
        self.workspace = workspace; self.drafts = drafts; self.includesDrafts = includesDrafts; self.review = review; self.includesReview = includesReview
    }
    public func encoded() throws -> Data {
        try workspace.validate()
        try validateDrafts()
        // No export timestamp: unchanged content must have a stable backup fingerprint.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(format: "branchline.migration", version: 2, workspace: workspace, drafts: drafts.sorted { $0.id < $1.id }, review: review))
    }
    public static func decoded(_ bytes: Data) throws -> MigrationBackup {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw WorkspaceError("备份不是有效的对象。") }
        guard object["format"] != nil else { return MigrationBackup(workspace: try Workspace.decoded(bytes), drafts: [], includesDrafts: false, includesReview: false) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Envelope.self, from: bytes)
        guard value.format == "branchline.migration", (1...2).contains(value.version) else { throw WorkspaceError("不支持这份迁移备份的格式。") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let normalized = try Workspace.decoded(encoder.encode(value.workspace))
        let result = MigrationBackup(workspace: normalized, drafts: value.drafts, review: value.review, includesReview: value.version >= 2)
        try result.workspace.validate(); try result.validateDrafts()
        return result
    }
    private func validateDrafts() throws {
        guard Set(drafts.map(\.id)).count == drafts.count,
              drafts.allSatisfy({ $0.recurrence.map { RecurrenceScope(rawValue: $0.scope) != nil } ?? true }) else { throw WorkspaceError("迁移备份中的草稿标识或修改范围无效。") }
    }
    private struct Envelope: Codable { var format: String; var version: Int; var workspace: Workspace; var drafts: [RecordDraft]; var review: ReviewDraft? }
}

public struct MigrationRestoreFailure: LocalizedError {
    public var recoveryRequired: Bool
    public var errorDescription: String? { recoveryRequired ? "恢复尚未完成，已停止写入。请重新打开应用完成恢复。" : "恢复失败，当前工作区与草稿已还原。" }
}

/// A journal makes the SQLite workspace and separate draft file recover as one operation.
/// A completed journal is retained as an empty state; no files are deleted.
public struct MigrationRestoreJournal {
    public var url: URL
    public init(url: URL) { self.url = url }
    public func recover(saveWorkspace: (Workspace) throws -> Void, saveDrafts: ([RecordDraft]) throws -> Void, saveReview: (ReviewDraft?) throws -> Void = { _ in }) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw WorkspaceError("恢复日志格式不受支持，原文件已保留。") }
        if let data = state.pending {
            let target = try MigrationBackup.decoded(data)
            try saveDrafts(target.drafts); if target.includesReview { try saveReview(target.review) }; try saveWorkspace(target.workspace); try write(nil)
        }
    }
    public func apply(_ target: MigrationBackup, previous: MigrationBackup, saveWorkspace: (Workspace) throws -> Void, saveDrafts: ([RecordDraft]) throws -> Void, saveReview: (ReviewDraft?) throws -> Void = { _ in }) throws {
        let next = try target.encoded(), before = try previous.encoded()
        try write(next)
        do { try saveDrafts(target.drafts); if target.includesReview { try saveReview(target.review) }; try saveWorkspace(target.workspace); try write(nil) }
        catch {
            // Persist the rollback intent before changing either store again.
            do { try write(before) } catch { throw MigrationRestoreFailure(recoveryRequired: true) }
            do { try saveDrafts(previous.drafts); if previous.includesReview { try saveReview(previous.review) }; try saveWorkspace(previous.workspace); try write(nil) }
            catch { throw MigrationRestoreFailure(recoveryRequired: true) }
            throw MigrationRestoreFailure(recoveryRequired: false)
        }
    }
    private func write(_ pending: Data?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(State(version: 1, pending: pending)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private struct State: Codable { var version: Int; var pending: Data? }
}
