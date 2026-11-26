import Foundation

public enum DeletionTarget: Equatable, Sendable {
    case project(UUID), branch(UUID), record(UUID), merge(UUID)
}

public struct DeletionPreview: Sendable {
    public let title: String
    public let detail: String
}

extension Workspace {
    public func deletionPreview(_ target: DeletionTarget) throws -> DeletionPreview {
        let next = try deleting(target)
        let title: String
        var notes: [String] = []
        switch target {
        case .project(let id):
            title = project(id)!.title
            let shared = branches.filter { $0.projectIDs.contains(id) && $0.projectIDs.count > 1 }.count
            let sharedRecords = records.filter { $0.branchID == nil && $0.projectIDs.contains(id) && Set($0.projectIDs).count > 1 }.count
            notes.append("共享分支保留 \(shared) 条，共享主干记录保留 \(sharedRecords) 条，仅解除与本项目的关联。分支起点若属于本项目，将改为独立起点。")
        case .branch(let id):
            let item = branch(id)!
            title = item.title
            notes.append("此分支将从全部 \(item.projectIDs.count) 个关联项目中移除，分支内记录与合并成果一并删除。关联项目本身保留。")
            let children = branches.filter { $0.originBranchID == id }.count
            if children > 0 { notes.append("\(children) 条子分支及其记录保留，起点改为独立起点；向已删除父分支的合并将移除。") }
        case .record(let id):
            let item = record(id)!
            title = item.title
            if item.taskSeriesID != nil { notes.append("仅删除这次任务，其余次数与后续重复计划保留。") }
            if item.repeatRule != .none { notes.append("这是一项重复会议，将删除整个系列及其未来提醒。") }
            notes.append("已合并的文字摘要保留，仅移除对该记录的引用。")
        case .merge(let id):
            title = merges.first { $0.id == id }!.summary
            notes.append("来源记录保留；分支当前状态和结束日期保持不变，如需重新开启请编辑分支。")
        }
        let removed = Set(records.map(\.id)).subtracting(next.records.map(\.id))
        let dependents = next.records.filter { remaining in records.first { $0.id == remaining.id }!.dependencies.contains { removed.contains($0) } }.count
        notes.insert("将删除 \(projects.count - next.projects.count) 个项目、\(branches.count - next.branches.count) 条分支、\(removed.count) 条记录和 \(merges.count - next.merges.count) 条合并成果。", at: 0)
        if dependents > 0 { notes.append("\(dependents) 项任务将移除已删除的依赖，可能因此解除等待；不会自动标记完成。") }
        notes.append("相关提醒会同步移除。本次删除可在回收站单独恢复；删除前也会保存完整备份。")
        return DeletionPreview(title: title, detail: notes.joined(separator: "\n\n"))
    }

    /// Compute a validated value first so failed deletion never partially mutates the workspace.
    public func deleting(_ target: DeletionTarget) throws -> Workspace {
        var next = self
        var removedProjects = Set<UUID>(), removedBranches = Set<UUID>(), removedRecords = Set<UUID>(), removedMerges = Set<UUID>()
        switch target {
        case .project(let id):
            guard project(id) != nil else { throw WorkspaceError("项目已不存在。") }
            removedProjects.insert(id)
            removedBranches = Set(branches.filter { Set($0.projectIDs) == [id] }.map(\.id))
        case .branch(let id):
            guard branch(id) != nil else { throw WorkspaceError("分支已不存在。") }
            removedBranches.insert(id)
        case .record(let id):
            guard record(id) != nil else { throw WorkspaceError("记录已不存在。") }
            removedRecords.insert(id)
            removedRecords.formUnion(records.filter { $0.seriesID == id }.map(\.id))
        case .merge(let id):
            guard merges.contains(where: { $0.id == id }) else { throw WorkspaceError("合并成果已不存在。") }
            removedMerges.insert(id)
        }
        for record in records {
            if let branch = record.branchID {
                if removedBranches.contains(branch) { removedRecords.insert(record.id) }
            } else if !record.projectIDs.isEmpty && Set(record.projectIDs).isSubset(of: removedProjects) {
                removedRecords.insert(record.id)
            }
        }
        removedRecords.formUnion(records.filter { $0.seriesID.map { removedRecords.contains($0) } == true }.map(\.id))
        for merge in merges where merge.projectID.map({ removedProjects.contains($0) }) == true || removedBranches.contains(merge.branchID) || merge.targetBranchID.map({ removedBranches.contains($0) }) == true { removedMerges.insert(merge.id) }
        next.projects.removeAll { removedProjects.contains($0.id) }
        next.branches.removeAll { removedBranches.contains($0.id) }
        for i in next.branches.indices {
            next.branches[i].projectIDs.removeAll { removedProjects.contains($0) }
            if let origin = next.branches[i].originProjectID, removedProjects.contains(origin) { next.branches[i].originProjectID = nil }
            if let parent = next.branches[i].originBranchID, removedBranches.contains(parent) { next.branches[i].originBranchID = nil }
        }
        if var plans = next.taskPlans {
            for index in plans.indices {
                if case .record(let id) = target, let item = record(id), item.taskSeriesID == plans[index].id, let date = item.taskOccurrence { plans[index].excluded.append(date) }
                plans[index].prototype.projectIDs.removeAll { removedProjects.contains($0) }
                plans[index].prototype.dependencies.removeAll { removedRecords.contains($0) }
            }
            plans.removeAll { $0.prototype.branchID.map { removedBranches.contains($0) } == true || ($0.prototype.branchID == nil && $0.prototype.projectIDs.isEmpty) }
            next.taskPlans = plans
        }
        next.records.removeAll { removedRecords.contains($0.id) }
        for i in next.records.indices {
            next.records[i].projectIDs.removeAll { removedProjects.contains($0) }
            next.records[i].dependencies.removeAll { removedRecords.contains($0) }
            if let series = next.records[i].taskSeriesID, !(next.taskPlans ?? []).contains(where: { $0.id == series }) { next.records[i].taskSeriesID = nil; next.records[i].taskOccurrence = nil; next.records[i].taskRepeatRule = nil; next.records[i].taskRepeatUntil = nil }
            if next.records[i] != record(next.records[i].id) { next.records[i].updatedAt = Date() }
        }
        next.merges.removeAll { removedMerges.contains($0.id) }
        for i in next.merges.indices { next.merges[i].sourceRecordIDs.removeAll { removedRecords.contains($0) } }
        let removedEntities = removedProjects.union(removedBranches).union(removedRecords).union(removedMerges)
        next.history.removeAll { removedEntities.contains($0.entityID) }
        try next.validate()
        return next
    }
}
