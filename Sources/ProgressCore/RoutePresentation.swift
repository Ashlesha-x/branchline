import Foundation

public struct RoutePlacement: Identifiable, Sendable {
    public var id: UUID
    public var ownerProjectID: UUID?
    public var depth: Int
    public var groupStatus: WorkStatus? = nil
}

public struct RouteRelation: Identifiable, Sendable {
    public enum Kind: Sendable { case fork, merge }
    public var id: String
    public var source: UUID
    public var target: UUID
    public var date: Date
    public var kind: Kind
    public var entityID: UUID
}

public struct RouteSummary: Sendable {
    public var pending: Int
    public var overdue: Int
    public var upcoming: [WorkRecord]
    public var latestUpdate: Date?
}

extension Workspace {
    public func timelineDates(of record: WorkRecord, in interval: DateInterval, now: Date, history: Bool) -> [Date] {
        let duration = record.kind == .meeting ? max(0, (record.endAt ?? record.startAt).timeIntervalSince(record.startAt)) : 0
        let future = DateInterval(start: min(interval.end, max(interval.start, now.addingTimeInterval(-duration))), end: interval.end)
        var dates = CalendarLogic.occurrences(of: record, in: future).filter { $0.addingTimeInterval(duration) >= now }
        // Enumerate future separately: the historical recurrence safety cap must
        // never make an expanded route lose future meetings it showed compactly.
        if history, interval.start < now {
            dates += CalendarLogic.occurrences(of: record, in: DateInterval(start: interval.start, end: min(now, interval.end)))
        }
        return Array(Set(dates)).sorted()
    }

    public func branchIsIndependent(_ id: UUID) -> Bool {
        var current = branch(id), seen = Set<UUID>()
        while let value = current, seen.insert(value.id).inserted {
            if value.projectIDs.count != 1 { return true }
            guard let parent = branch(value.originBranchID) else { return false }
            current = parent
        }
        return false
    }

    /// A display projection. Siblings retain the stored manual order; independent and shared
    /// routes remain at the root without changing their project associations.
    public func routePlacements(projectIDs visible: [UUID], collapsed: Set<UUID> = [], includeIndependent: Bool = true, includeAllIndependent: Bool = false) -> [RoutePlacement] {
        let open = visible.filter { !collapsed.contains($0) }
        let candidates = branches.filter { (includeIndependent && ($0.projectIDs.isEmpty || (includeAllIndependent && branchIsIndependent($0.id)))) || !$0.projectIDs.filter { open.contains($0) }.isEmpty }
        let allowed = Set(candidates.map(\.id))
        var owners: [UUID: UUID] = [:], resolved = Set<UUID>()
        func owner(_ branch: Branch) -> UUID? {
            if resolved.contains(branch.id) { return owners[branch.id] }
            resolved.insert(branch.id)
            if branchIsIndependent(branch.id) { return nil }
            let linked = branch.projectIDs.filter { open.contains($0) }
            let result: UUID?
            if let parent = self.branch(branch.originBranchID), allowed.contains(parent.id), let inherited = owner(parent), linked.contains(inherited) { result = inherited }
            else if let origin = branch.originProjectID, linked.contains(origin) { result = origin }
            else { result = linked.first }
            owners[branch.id] = result
            return result
        }
        for branch in candidates { _ = owner(branch) }
        var result: [RoutePlacement] = [], seen = Set<UUID>()
        func group(_ project: UUID?) {
            let members = candidates.filter { owners[$0.id] == project }
            let ids = Set(members.map(\.id))
            func append(_ branch: Branch, depth: Int) {
                guard seen.insert(branch.id).inserted else { return }
                result.append(RoutePlacement(id: branch.id, ownerProjectID: project, depth: depth))
                for child in members where child.originBranchID == branch.id { append(child, depth: depth + 1) }
            }
            for branch in members where branch.originBranchID.map({ !ids.contains($0) }) ?? true { append(branch, depth: 0) }
            for branch in members where !seen.contains(branch.id) { append(branch, depth: 0) }
        }
        for project in visible {
            result.append(RoutePlacement(id: project, ownerProjectID: project, depth: 0))
            group(project)
        }
        group(nil)
        return result
    }

    public var routeRelations: [RouteRelation] {
        branches.compactMap { branch in
            (branch.originBranchID ?? branch.originProjectID).map { RouteRelation(id: "fork-\(branch.id)", source: $0, target: branch.id, date: branch.startAt, kind: .fork, entityID: branch.id) }
        } + merges.compactMap { merge in
            merge.targetLaneID.map { RouteRelation(id: "merge-\(merge.id)", source: merge.branchID, target: $0, date: merge.date, kind: .merge, entityID: merge.id) }
        }
    }

    public func routeTasks(_ id: UUID) -> [WorkRecord] {
        let values = records.filter { record in
            project(id) != nil ? projects(for: record).contains(id) : record.branchID == id
        }
        return values.filter { $0.kind == .task && $0.status == .active }.sorted {
            if $0.dueAt != $1.dueAt { return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    public func routeSummary(_ id: UUID, now: Date, calendar: Calendar = .current) -> RouteSummary {
        let values = records.filter { project(id) != nil ? projects(for: $0).contains(id) : $0.branchID == id }
        let tasks = routeTasks(id)
        let day = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: day)!
        let upcoming = tasks.filter { record in
            guard let due = record.dueAt else { return false }
            return !CalendarLogic.deadlinePassed(record, now: now) && due >= day && due < end
        }.sorted { $0.dueAt == $1.dueAt ? $0.id.uuidString < $1.id.uuidString : $0.dueAt! < $1.dueAt! }
        return RouteSummary(pending: tasks.count, overdue: tasks.filter { CalendarLogic.deadlinePassed($0, now: now) }.count, upcoming: upcoming, latestUpdate: values.map(\.updatedAt).max())
    }
}
