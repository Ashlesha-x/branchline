import Foundation

/// A branch is one destination even when shared by multiple projects.
public struct RecordingLocation: Codable, Hashable, Sendable {
    public var branchID: UUID?
    public var projectIDs: [UUID]
    public init(branchID: UUID) { self.branchID = branchID; projectIDs = [] }
    public init(projectIDs: [UUID]) { branchID = nil; self.projectIDs = Array(Set(projectIDs)).sorted { $0.uuidString < $1.uuidString } }
    public func exists(in workspace: Workspace) -> Bool {
        if let branchID { return projectIDs.isEmpty && workspace.branch(branchID) != nil }
        return !projectIDs.isEmpty && Set(projectIDs).count == projectIDs.count && projectIDs.allSatisfy { workspace.project($0) != nil }
    }
    public func isArchived(in workspace: Workspace) -> Bool {
        if let branchID, let branch = workspace.branch(branchID) {
            return branch.status == .archived || (!branch.projectIDs.isEmpty && branch.projectIDs.allSatisfy { workspace.project($0)?.status == .archived })
        }
        return projectIDs.contains { workspace.project($0)?.status == .archived }
    }
    public func belongs(to project: UUID, in workspace: Workspace) -> Bool {
        branchID.flatMap { workspace.branch($0)?.projectIDs.contains(project) } ?? projectIDs.contains(project)
    }
    public func title(in workspace: Workspace) -> String {
        if let branchID { return workspace.branch(branchID)?.title ?? "位置已删除" }
        return projectIDs.compactMap { workspace.project($0)?.title }.joined(separator: "、") + " · 主干"
    }
    public func detail(in workspace: Workspace) -> String {
        guard let branchID, let branch = workspace.branch(branchID) else { return "" }
        return branch.projectIDs.isEmpty ? "独立分支" : branch.projectIDs.compactMap { workspace.project($0)?.title }.joined(separator: "、")
    }
    public func applying(to input: WorkRecord) -> WorkRecord {
        var record = input; record.branchID = branchID; record.projectIDs = projectIDs; return record
    }
}
public enum RecordingContext: Sendable {
    case project(UUID), branch(UUID), record(UUID), merge(UUID)
}
extension WorkRecord {
    public var recordingLocation: RecordingLocation? {
        if let branchID { return RecordingLocation(branchID: branchID) }
        return projectIDs.isEmpty ? nil : RecordingLocation(projectIDs: projectIDs)
    }
}
extension Workspace {
    public func lastRecordingLocation(in history: [RecordingLocation]) -> RecordingLocation? {
        guard let first = history.first, first.exists(in: self), !first.isArchived(in: self) else { return nil }
        return first
    }
    public func recordingLocation(explicit: RecordingLocation? = nil, context: RecordingContext?, projectFilter: UUID?) -> RecordingLocation? {
        // A vanished explicit destination must never silently fall back elsewhere.
        if let explicit { return explicit.exists(in: self) ? explicit : nil }
        let candidate: RecordingLocation?
        switch context {
        case .project(let id): candidate = RecordingLocation(projectIDs: [id])
        case .branch(let id): candidate = RecordingLocation(branchID: id)
        case .record(let id): candidate = record(id)?.recordingLocation
        case .merge(let id): candidate = merges.first { $0.id == id }.map { RecordingLocation(branchID: $0.branchID) }
        case nil: candidate = nil
        }
        if let candidate, candidate.exists(in: self), !candidate.isArchived(in: self),
           projectFilter.map({ candidate.belongs(to: $0, in: self) }) ?? true { return candidate }
        if let projectFilter {
            let location = RecordingLocation(projectIDs: [projectFilter])
            if location.exists(in: self), !location.isArchived(in: self) { return location }
        }
        return nil
    }
}
