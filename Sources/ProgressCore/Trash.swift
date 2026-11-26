import Foundation

public enum TrashEntity: String, Codable, Sendable { case project, branch, record, merge, history, taskPlan }
public struct TrashChange: Codable, Equatable, Sendable {
    public var kind: TrashEntity
    public var id: UUID
    public var before: Data
    public var after: Data?
}
public struct TrashEntry: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var deletedAt = Date()
    public var title: String
    public var changes: [TrashChange]
    public var summary: String {
        let removed = changes.filter { $0.after == nil }
        if removed.isEmpty { return "取消的会议日期与重复范围" }
        return "\(removed.filter { $0.kind == .project }.count) 个项目 · \(removed.filter { $0.kind == .branch }.count) 条分支 · \(removed.filter { $0.kind == .record }.count) 条记录 · \(removed.filter { $0.kind == .merge }.count) 条成果"
    }
    public func validate() throws {
        guard !changes.isEmpty, Set(changes.map(\.id)).count == changes.count else { throw WorkspaceError("回收站内容无效。") }
        func check<T: Decodable & Identifiable>(_ type: T.Type, _ change: TrashChange) throws where T.ID == UUID {
            guard try JSONDecoder().decode(type, from: change.before).id == change.id else { throw WorkspaceError("回收站内容标识不匹配。") }
            if let after = change.after, try JSONDecoder().decode(type, from: after).id != change.id { throw WorkspaceError("回收站变更标识不匹配。") }
        }
        for change in changes {
            switch change.kind {
            case .project: try check(Project.self, change)
            case .branch: try check(Branch.self, change)
            case .record: try check(WorkRecord.self, change)
            case .merge: try check(MergeRecord.self, change)
            case .history: try check(ChangeRecord.self, change)
            case .taskPlan: try check(TaskPlan.self, change)
            }
        }
    }
}

extension Workspace {
    /// Store only removed entities and changed survivors, never nested workspace snapshots.
    public func retainingDeletion(from before: Workspace, title: String) throws -> Workspace {
        var next = self
        var changes: [TrashChange] = []
        func diff<T: Codable & Equatable & Identifiable>(_ old: [T], _ new: [T], kind: TrashEntity) throws where T.ID == UUID {
            let lookup = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
            for item in old where lookup[item.id] != item {
                changes.append(TrashChange(kind: kind, id: item.id, before: try JSONEncoder().encode(item), after: try lookup[item.id].map { try JSONEncoder().encode($0) }))
            }
        }
        try diff(before.projects, projects, kind: .project)
        try diff(before.branches, branches, kind: .branch)
        try diff(before.records, records, kind: .record)
        try diff(before.merges, merges, kind: .merge)
        try diff(before.history, history, kind: .history)
        try diff(before.taskPlans ?? [], taskPlans ?? [], kind: .taskPlan)
        guard !changes.isEmpty else { throw WorkspaceError("没有可放入回收站的删除内容。") }
        next.trashEntries = trash + [TrashEntry(title: title, changes: changes)]
        try next.validate()
        return next
    }
    public func movingToTrash(_ target: DeletionTarget) throws -> Workspace {
        let title = try deletionPreview(target).title
        return try deleting(target).retainingDeletion(from: self, title: title)
    }
    public func restoringTrash(_ id: UUID) throws -> Workspace {
        guard let entry = trash.first(where: { $0.id == id }) else { throw WorkspaceError("此删除操作已恢复或不存在。") }
        var next = self
        func restore<T: Codable & Identifiable>(_ items: inout [T], change: TrashChange) throws where T.ID == UUID {
            let before = try JSONDecoder().decode(T.self, from: change.before)
            guard let afterData = change.after else {
                guard !items.contains(where: { $0.id == change.id }) else { throw WorkspaceError("同一内容已存在，未覆盖现有内容。") }
                items.append(before); return
            }
            guard let i = items.firstIndex(where: { $0.id == change.id }) else { throw WorkspaceError("关联内容后来也被删除，请先恢复后一次删除。") }
            let old = try JSONSerialization.jsonObject(with: change.before) as! [String: Any]
            let after = try JSONSerialization.jsonObject(with: afterData) as! [String: Any]
            var current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(items[i])) as! [String: Any]
            func equal(_ a: Any?, _ b: Any?) -> Bool {
                (a == nil && b == nil) || (a as? NSObject)?.isEqual(b) == true
            }
            // Undo only fields touched by deletion; keep later edits to unrelated fields.
            for key in Set(old.keys).union(after.keys) where key != "updatedAt" && !equal(old[key], after[key]) {
                guard equal(current[key], after[key]) || equal(current[key], old[key]) else { throw WorkspaceError("关联关系后来发生变化，无法安全恢复。请先处理后续关联修改；现有内容未改动。") }
                current[key] = old[key]
            }
            if current["updatedAt"] != nil { current["updatedAt"] = Date().timeIntervalSinceReferenceDate }
            items[i] = try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: current))
        }
        for change in entry.changes {
            switch change.kind {
            case .project: try restore(&next.projects, change: change)
            case .branch: try restore(&next.branches, change: change)
            case .record: try restore(&next.records, change: change)
            case .merge: try restore(&next.merges, change: change)
            case .history: try restore(&next.history, change: change)
            case .taskPlan: var plans = next.taskPlans ?? []; try restore(&plans, change: change); next.taskPlans = plans
            }
        }
        next.trashEntries = trash.filter { $0.id != id }
        do { try next.validate() }
        catch { throw WorkspaceError("恢复需要的项目、分支或日期关系已变化，请先恢复关联内容。\(error.localizedDescription)") }
        return next
    }
}
