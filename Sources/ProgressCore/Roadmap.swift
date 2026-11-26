import Foundation

public enum RoadmapEventKind: String, Sendable { case start, end, archive, record, deadline, merge, statusGroup, taskSeries }
public struct RoadmapEvent: Identifiable, Sendable {
    public var id: String
    public var laneID: UUID
    public var date: Date
    public var kind: RoadmapEventKind
    public var title: String
    public var entityID: UUID
    public var sourceLaneID: UUID?
    public var taskFamilyID: UUID? = nil
    public var taskCount: Int? = nil
    public var through: Date? = nil
}
public struct RoadmapRow: Identifiable, Sendable {
    public var events: [RoadmapEvent]
    public var id: String { events[0].id }
    public var laneID: UUID { events[0].laneID }
    public var date: Date { events[0].date }
}

extension Workspace {
    /// Empty calendar intervals never allocate rows. A repeated series is one event;
    /// its individual future occurrences remain available in the calendar timeline.
    public func roadmap(projectIDs visible: Set<UUID>, collapsed: Set<UUID>, records visibleRecords: [WorkRecord], includeIndependent: Bool, summary: Set<UUID> = [], now: Date = Date(), visibleLaneIDs: Set<UUID>? = nil, groupDistantTasks: Bool = false, expandedTaskFamilies: Set<UUID> = [], revealedRecordID: UUID? = nil) -> [RoadmapRow] {
        let shownBranches = branches.filter { branch in
            if let visibleLaneIDs { return visibleLaneIDs.contains(branch.id) }
            return (includeIndependent && branch.projectIDs.isEmpty) || branch.projectIDs.contains { visible.contains($0) && !collapsed.contains($0) }
        }
        let branchIDs = Set(shownBranches.map(\.id))
        var events: [RoadmapEvent] = []
        let until = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now))!
        var distantGroups: [String: Int] = [:]
        func add(_ id: String, _ lane: UUID, _ date: Date, _ kind: RoadmapEventKind, _ title: String, _ entity: UUID, source: UUID? = nil) {
            events.append(RoadmapEvent(id: id, laneID: lane, date: date, kind: kind, title: title, entityID: entity, sourceLaneID: source))
        }
        for project in projects where visible.contains(project.id) {
            if let visibleLaneIDs, !visibleLaneIDs.contains(project.id) { continue }
            guard !collapsed.contains(project.id) || summary.contains(project.id) else { continue }
            add("start-\(project.id)", project.id, project.createdAt, .start, "项目起点", project.id)
            if let end = project.closedAt { add("end-\(project.id)", project.id, end, .end, "项目结束", project.id) }
            if let archive = project.archivedAt { add("archive-\(project.id)", project.id, archive, .archive, "项目归档", project.id) }
        }
        for branch in shownBranches {
            add("start-\(branch.id)", branch.id, branch.startAt, .start, "分支起点", branch.id, source: branch.originBranchID ?? branch.originProjectID)
            if let end = branch.closedAt { add("end-\(branch.id)", branch.id, end, .end, "分支结束", branch.id) }
            if let archive = branch.archivedAt { add("archive-\(branch.id)", branch.id, archive, .archive, "分支归档", branch.id) }
        }
        for record in visibleRecords {
            let lanes = record.branchID.map { branchIDs.contains($0) ? [$0] : [] } ?? record.projectIDs.filter { visible.contains($0) && (!collapsed.contains($0) || summary.contains($0)) && (visibleLaneIDs?.contains($0) ?? true) }
            for lane in lanes {
                let actualDates = [record.hasPlannedStart ? record.startAt : nil, record.dueAt].compactMap { $0 }
                let firstDate = actualDates.min() ?? record.taskOccurrence ?? record.startAt
                if groupDistantTasks, record.kind == .task, record.status == .active || record.status == .paused,
                   let family = taskFamilyID(for: record), !expandedTaskFamilies.contains(family), record.id != revealedRecordID, firstDate >= until {
                    // Group by both family and lane: a single occurrence can have its own location.
                    let key = "future-\(family)-\(lane)"
                    let lastDate = actualDates.max() ?? firstDate
                    if let index = distantGroups[key] {
                        events[index].taskCount = (events[index].taskCount ?? 1) + 1
                        events[index].through = max(events[index].through ?? lastDate, lastDate)
                        if firstDate < events[index].date { events[index].date = firstDate; events[index].title = record.title; events[index].entityID = record.id }
                    } else {
                        distantGroups[key] = events.count
                        events.append(RoadmapEvent(id: key, laneID: lane, date: firstDate, kind: .taskSeries, title: record.title, entityID: record.id, taskFamilyID: family, taskCount: 1, through: lastDate))
                    }
                    continue
                }
                add("record-\(record.id)-\(lane)", lane, record.kind == .task && !record.hasPlannedStart ? record.createdAt : record.startAt, .record, record.kind == .task && !record.hasPlannedStart ? "任务录入 · " + record.title : record.title, record.id)
                if let due = record.dueAt { add("due-\(record.id)-\(lane)", lane, due, .deadline, "截止 · \(record.title)", record.id) }
                if let end = record.completedAt ?? record.endAt, record.kind == .task { add("end-record-\(record.id)-\(lane)", lane, end, .record, "\(record.completedAt == nil ? "计划结束" : "完成") · \(record.title)", record.id) }
            }
        }
        for merge in merges {
            guard let target = merge.targetLaneID else { continue }
            let shown = merge.targetBranchID != nil ? branchIDs.contains(target) : visible.contains(target) && (!collapsed.contains(target) || summary.contains(target))
            guard shown, visibleLaneIDs?.contains(target) ?? true else { continue }
            add("merge-\(merge.id)", target, merge.date, .merge, merge.summary, merge.id, source: merge.branchID)
        }
        let shown = events.filter { event in
            guard summary.contains(event.laneID) else { return true }
            if event.entityID == revealedRecordID { return true }
            if !expandedTaskFamilies.isEmpty, let record = self.record(event.entityID), let family = taskFamilyID(for: record), expandedTaskFamilies.contains(family) { return true }
            if event.kind == .record { return false }
            if event.kind == .deadline { return self.record(event.entityID)?.status == .active && event.date < until }
            return true
        }
        let ordered = shown.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        var rows: [RoadmapRow] = []
        for event in ordered {
            // Only combine adjacent records. Never collapse across a merge or a fork.
            if event.kind == .record, let last = rows.last, last.events.allSatisfy({ $0.kind == .record }), last.laneID == event.laneID, Calendar.current.isDate(last.date, inSameDayAs: event.date) {
                rows[rows.count - 1].events.append(event)
            } else { rows.append(RoadmapRow(events: [event])) }
        }
        return rows
    }
}
