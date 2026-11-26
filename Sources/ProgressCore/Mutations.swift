import Foundation

// All writers use these domain operations inside a single workspace transaction.
// UI prompts and transport permissions belong to their respective adapters.
extension Workspace {
    public mutating func putProject(_ input: Project) throws {
        var value = input
        if value.status != .archived && occupiedRouteColors(excluding: value.id).contains(value.color) { value.color = availableRouteColor(excluding: value.id) }
        let old = project(value.id)
        if let i = projects.firstIndex(where: { $0.id == value.id }) { projects[i] = value } else { projects.append(value) }
        if let old, old.status != value.status { history.append(ChangeRecord(entityID: value.id, summary: "状态：\(old.status.title) → \(value.status.title)")) }
        if let old, old.closedAt != value.closedAt || old.archivedAt != value.archivedAt { history.append(ChangeRecord(entityID: value.id, summary: "时间更新：结束 \(value.closedAt.map { WorkDateText.date($0, timed: true) } ?? "未设置")；归档 \(value.archivedAt.map { WorkDateText.date($0, timed: true) } ?? "未设置")。")) }
    }
    public mutating func putBranch(_ input: Branch) throws {
        var value = input
        if value.status != .archived && occupiedRouteColors(excluding: value.id).contains(value.color) { value.color = availableRouteColor(excluding: value.id) }
        let old = branch(value.id)
        if let i = branches.firstIndex(where: { $0.id == value.id }) { branches[i] = value } else { branches.append(value) }
        if let old, old.status != value.status { history.append(ChangeRecord(entityID: value.id, summary: "状态：\(old.status.title) → \(value.status.title)")) }
        if let old, Set(old.projectIDs) != Set(value.projectIDs) { history.append(ChangeRecord(entityID: value.id, summary: "更新了分支关联的项目。")) }
        if let old, old.closedAt != value.closedAt || old.archivedAt != value.archivedAt { history.append(ChangeRecord(entityID: value.id, summary: "时间更新：结束 \(value.closedAt.map { WorkDateText.date($0, timed: true) } ?? "未设置")；归档 \(value.archivedAt.map { WorkDateText.date($0, timed: true) } ?? "未设置")。")) }
    }
    /// `checkDependencies: false` lets a batch defer the blocker check to its final state.
    public mutating func putRecord(_ input: WorkRecord, now: Date = Date(), checkDependencies: Bool = true) throws {
        var value = input; value.updatedAt = now
        if value.status == .completed && value.completedAt == nil { value.completedAt = now }
        if value.status != .completed { value.completedAt = nil }
        let old = record(value.id)
        if checkDependencies && value.status == .completed && old?.status != .completed && !blockedBy(value).isEmpty { throw WorkspaceError("这项任务还有未完成的依赖。") }
        if let i = records.firstIndex(where: { $0.id == value.id }) { records[i] = value } else { records.append(value) }
        if let old {
            if old.dueAt != value.dueAt { history.append(ChangeRecord(entityID: value.id, summary: "截止日期：\(old.dueAt.map { WorkDateText.date($0) } ?? "未设置") → \(value.dueAt.map { WorkDateText.date($0) } ?? "未设置")")) }
            if old.startAt != value.startAt { history.append(ChangeRecord(entityID: value.id, summary: "开始 / 发生时间：\(WorkDateText.date(old.startAt)) → \(WorkDateText.date(value.startAt))")) }
            if old.status != value.status { history.append(ChangeRecord(entityID: value.id, summary: "状态：\(old.status.title) → \(value.status.title)")) }
        }
    }
    public mutating func addMerge(_ merge: MergeRecord) throws {
        guard merge.sourceRecordIDs.allSatisfy({ (record($0)?.startAt ?? .distantFuture) <= merge.date }) else { throw WorkspaceError("不能引用合并时间之后的记录。") }
        merges.append(merge)
        history.append(ChangeRecord(entityID: merge.branchID, summary: "成果合并至「\(mergeTargetTitle(merge))」；\(merge.closesBranch ? "结束分支" : "继续分支")。"))
        if merge.closesBranch, let i = branches.firstIndex(where: { $0.id == merge.branchID }) { branches[i].status = .completed; branches[i].closedAt = merge.date }
    }
}
