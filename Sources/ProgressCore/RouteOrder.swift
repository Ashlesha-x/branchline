import Foundation

extension Workspace {
    public func canReorder(_ source: UUID, relativeTo target: UUID) -> Bool {
        guard source != target else { return false }
        if project(source) != nil && project(target) != nil { return true }
        guard let a = branch(source), let b = branch(target) else { return false }
        return (branchIsIndependent(a.id) && branchIsIndependent(b.id)) || !Set(a.projectIDs).isDisjoint(with: b.projectIDs)
    }
    public func reordering(_ source: UUID, relativeTo target: UUID, after: Bool) throws -> Workspace {
        guard canReorder(source, relativeTo: target) else { throw WorkspaceError("项目只能与项目排序；分支只能在同一关联项目内排序，独立分支可相互排序。") }
        var next = self
        func move<T: Identifiable>(_ items: inout [T]) where T.ID == UUID {
            guard let index = items.firstIndex(where: { $0.id == source }) else { return }
            let item = items.remove(at: index)
            guard let destination = items.firstIndex(where: { $0.id == target }) else { return }
            items.insert(item, at: destination + (after ? 1 : 0))
        }
        if project(source) != nil { move(&next.projects) } else { move(&next.branches) }
        try next.validate()
        return next
    }
}
