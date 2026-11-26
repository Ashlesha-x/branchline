import Foundation

public enum RouteGroups {
    public static let statuses: [WorkStatus] = [.paused, .archived, .completed]
    // Stable presentation identities, never persisted as workspace entities.
    public static func id(_ status: WorkStatus) -> UUID {
        switch status {
        case .paused: UUID(uuidString: "6E875620-4F58-4212-A0A1-4F30DB9D0111")!
        case .archived: UUID(uuidString: "6E875620-4F58-4212-A0A1-4F30DB9D0222")!
        case .completed: UUID(uuidString: "6E875620-4F58-4212-A0A1-4F30DB9D0333")!
        case .active: UUID(uuidString: "6E875620-4F58-4212-A0A1-4F30DB9D0444")!
        }
    }
    public static func reordered(_ roots: [UUID], moving source: UUID, to target: UUID, after: Bool) -> [UUID] {
        guard source != target, roots.contains(source), roots.contains(target) else { return roots }
        var result = roots.filter { $0 != source }
        let index = result.firstIndex(of: target)!
        result.insert(source, at: index + (after ? 1 : 0))
        return result
    }
}

extension Workspace {
    /// Root order and status folding are display preferences. Child routes travel
    /// with their root; moving a shared route never changes its associations.
    public func presentedRoutes(projectIDs: [UUID], collapsed: Set<UUID> = [], includeIndependent: Bool = true, rootOrder: [UUID] = [], expandedStatuses: Set<WorkStatus> = []) -> [RoutePlacement] {
        let base = routePlacements(projectIDs: projectIDs, collapsed: collapsed, includeIndependent: includeIndependent, includeAllIndependent: includeIndependent)
        var blocks: [[RoutePlacement]] = []
        for item in base {
            if project(item.id) != nil || (item.ownerProjectID == nil && item.depth == 0) { blocks.append([item]) }
            else if !blocks.isEmpty { blocks[blocks.count - 1].append(item) }
        }
        let priorities = Dictionary(rootOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let ordered = blocks.enumerated().sorted {
            let a = priorities[$0.element[0].id] ?? rootOrder.count + $0.offset
            let b = priorities[$1.element[0].id] ?? rootOrder.count + $1.offset
            return a < b
        }.map(\.element)
        var result = ordered.filter { project($0[0].id)?.status ?? .active == .active }.flatMap { $0 }
        for status in RouteGroups.statuses {
            let values = ordered.filter { project($0[0].id)?.status == status }
            guard !values.isEmpty else { continue }
            result.append(RoutePlacement(id: RouteGroups.id(status), ownerProjectID: nil, depth: 0, groupStatus: status))
            if expandedStatuses.contains(status) { result += values.flatMap { $0 } }
        }
        return result
    }

    public func presentedRoadmap(projectIDs: [UUID], collapsed: Set<UUID>, records: [WorkRecord], includeIndependent: Bool, summary: Set<UUID>, layout: [RoutePlacement], now: Date = Date(), groupDistantTasks: Bool = false, expandedTaskFamilies: Set<UUID> = [], revealedRecordID: UUID? = nil) -> [RoadmapRow] {
        let allowed = Set(layout.filter { $0.groupStatus == nil }.map(\.id))
        let rows = roadmap(projectIDs: Set(projectIDs), collapsed: collapsed, records: records, includeIndependent: includeIndependent, summary: summary, now: now, visibleLaneIDs: allowed, groupDistantTasks: groupDistantTasks, expandedTaskFamilies: expandedTaskFamilies, revealedRecordID: revealedRecordID)
        let owners = Dictionary(layout.map { ($0.id, $0.ownerProjectID) }, uniquingKeysWith: { a, _ in a })
        func status(_ id: UUID) -> WorkStatus { owners[id].flatMap { $0 }.flatMap(project)?.status ?? .active }
        var result = rows.filter { status($0.laneID) == .active }
        for group in layout where group.groupStatus != nil {
            let value = group.groupStatus!
            result.append(RoadmapRow(events: [RoadmapEvent(id: "status-\(value.rawValue)", laneID: group.id, date: .distantPast, kind: .statusGroup, title: value.title, entityID: group.id)]))
            result += rows.filter { status($0.laneID) == value }
        }
        return result
    }
}
