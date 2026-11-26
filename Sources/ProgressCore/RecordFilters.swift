import Foundation

public enum RecordDateField: String, CaseIterable, Codable, Sendable {
    case occurrence = "发生日期", deadline = "截止日期", completion = "实际完成日期", entered = "录入日期"
    public func date(of record: WorkRecord) -> Date? {
        switch self {
        case .occurrence: record.kind == .task && !record.hasPlannedStart ? nil : record.startAt
        case .deadline: record.kind == .task ? record.dueAt : nil
        case .completion: record.kind == .task && record.status == .completed ? record.completedAt : nil
        case .entered: record.createdAt
        }
    }
}

public struct RecordFilter: Equatable, Sendable {
    public var projectID: UUID?
    public var branchID: UUID?
    public var taskStatus: WorkStatus?
    public var dateField: RecordDateField = .occurrence
    public var from: Date?
    public var through: Date?
    public init() {}
    public var isActive: Bool { branchID != nil || taskStatus != nil || from != nil || through != nil || dateField != .occurrence }
    public func includesDate(_ date: Date?, calendar: Calendar = .current) -> Bool {
        guard from != nil || through != nil else { return true }
        guard let date else { return false }
        if let from, date < calendar.startOfDay(for: from) { return false }
        if let through, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)), date >= end { return false }
        return true
    }
    public func matches(_ record: WorkRecord, in workspace: Workspace) -> Bool {
        if let projectID, !workspace.projects(for: record).contains(projectID) { return false }
        if let branchID, record.branchID != branchID { return false }
        if let taskStatus, record.kind != .task || record.status != taskStatus { return false }
        if dateField != .occurrence && dateField.date(of: record) == nil { return false }
        return includesDate(dateField.date(of: record))
    }
    public func matches(_ hit: SearchHit, in workspace: Workspace) -> Bool {
        if hit.kind == .record { return workspace.record(hit.id).map { matches($0, in: workspace) } ?? false }
        if taskStatus != nil || dateField != .occurrence { return false }
        switch hit.kind {
        case .project: return branchID == nil && (projectID == nil || projectID == hit.id) && includesDate(hit.date)
        case .branch: return (branchID == nil || branchID == hit.id) && (projectID == nil || workspace.branch(hit.id)?.projectIDs.contains(projectID!) == true) && includesDate(hit.date)
        case .merge:
            guard let merge = workspace.merges.first(where: { $0.id == hit.id }) else { return false }
            return (projectID == nil || merge.projectID == projectID || workspace.branch(merge.targetBranchID)?.projectIDs.contains(projectID!) == true) && (branchID == nil || merge.branchID == branchID) && includesDate(hit.date)
        case .record: return false
        }
    }
}
