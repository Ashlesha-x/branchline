import Foundation
import ProgressCore

func routeHierarchyKeepsSiblingsAndSharedWorkUnique() throws {
    var db = Workspace.demo()
    let parent = db.branches.first { $0.title == "交互设计" }!
    let child = db.branches.first { $0.originBranchID == parent.id }!
    let before = try db.encoded()
    let ids = db.projects.map(\.id)
    let layout = db.routePlacements(projectIDs: ids)
    let p = layout.firstIndex { $0.id == parent.id }!, c = layout.firstIndex { $0.id == child.id }!
    try expect(c == p + 1 && layout[c].depth == layout[p].depth + 1)
    try expect(Set(layout.map(\.id)).count == db.projects.count + db.branches.count)
    try expect(layout.count == Set(layout.map(\.id)).count)
    try expect(try db.encoded() == before)
    var sibling = Branch(title: "另一个子分支", projectIDs: parent.projectIDs)
    sibling.originBranchID = parent.id; sibling.startAt = child.startAt
    db.branches.insert(sibling, at: 0)
    let ordered = db.routePlacements(projectIDs: ids).map(\.id)
    try expect(ordered.firstIndex(of: sibling.id)! < ordered.firstIndex(of: child.id)!)
    let reordered = try db.reordering(child.id, relativeTo: sibling.id, after: false)
    let moved = reordered.routePlacements(projectIDs: ids).map(\.id)
    try expect(moved.firstIndex(of: child.id)! + 1 == moved.firstIndex(of: sibling.id)!)
    try expect(reordered.branch(child.id)?.originBranchID == parent.id)
}

func sharedRouteOwnerSurvivesProjectOrderAndCollapse() throws {
    var db = Workspace.demo()
    let shared = db.branches.first { $0.projectIDs.count > 1 }!
    let origin = try require(shared.originProjectID ?? shared.projectIDs.first)
    let reversed = db.routePlacements(projectIDs: db.projects.reversed().map(\.id))
    try expect(reversed.contains { $0.id == shared.id && $0.ownerProjectID == nil && $0.depth == 0 })
    let other = shared.projectIDs.first { $0 != origin }!
    let folded = db.routePlacements(projectIDs: db.projects.map(\.id), collapsed: [origin])
    try expect(folded.filter { $0.id == shared.id }.count == 1)
    try expect(folded.first { $0.id == shared.id }?.ownerProjectID == nil)
    let parent = db.branches.first { $0.projectIDs == [origin] }!
    var foreignChild = Branch(title: "范围外父分支", projectIDs: [other])
    foreignChild.originBranchID = parent.id; foreignChild.startAt = parent.startAt
    db.branches.append(foreignChild); try db.validate()
    let scoped = db.routePlacements(projectIDs: [other], includeIndependent: false)
    try expect(scoped.first { $0.id == foreignChild.id }?.depth == 0)
    try expect(!scoped.contains { $0.id == parent.id })
    let unlinked = try require(db.branches.first { $0.projectIDs.isEmpty })
    let reordered = try db.reordering(shared.id, relativeTo: unlinked.id, after: true)
    try expect(reordered.branches.firstIndex(where: { $0.id == shared.id })! > reordered.branches.firstIndex(where: { $0.id == unlinked.id })!)
    try expect(db.branchIsIndependent(shared.id))
    try expect(!db.branchIsIndependent(parent.id))
    var child = Branch(title: "独立方向的子分支", projectIDs: [other])
    child.originBranchID = shared.id; child.startAt = shared.startAt; db.branches.append(child)
    try expect(db.branchIsIndependent(child.id))
    let roots = db.routePlacements(projectIDs: [other], includeIndependent: false)
    try expect(roots.contains { $0.id == shared.id && $0.ownerProjectID == nil })
    try expect(roots.contains { $0.id == child.id && $0.ownerProjectID == nil && $0.depth == 1 })
}

func routeSummaryPreservesDeadlineMeaningAndCounts() throws {
    var db = Workspace()
    let project = Project(title: "摘要项目"), other = Project(title: "另一个项目")
    db.projects = [project, other]
    let shared = Branch(title: "共享任务", projectIDs: [project.id, other.id]); db.branches = [shared]
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
    func task(_ title: String, offset: Int, status: WorkStatus = .active) -> WorkRecord {
        var t = WorkRecord(kind: .task, title: title); t.branchID = shared.id; t.status = status; t.timeZoneID = "UTC"
        t.dueAt = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)); return t
    }
    db.records = [task("昨天截止", offset: -1), task("今天截止", offset: 0), task("后天截止", offset: 2), task("第八天截止", offset: 7), task("已完成", offset: -2, status: .completed)]
    let summary = db.routeSummary(project.id, now: now, calendar: cal)
    try expect(summary.pending == 4 && summary.overdue == 1)
    try expect(summary.upcoming.map(\.title) == ["今天截止", "后天截止"])
    try expect(db.routeSummary(shared.id, now: now, calendar: cal).pending == 4)
    try expect(db.routeSummary(other.id, now: now, calendar: cal).pending == 4)
}

func overviewKeepsMilestonesAndDeadlinesWithoutDailyNoise() throws {
    let db = Workspace.demo()
    let ids = Set(db.projects.map(\.id)), all = ids.union(db.branches.map(\.id))
    let now = Date()
    let rows = db.roadmap(projectIDs: ids, collapsed: [], records: db.records, includeIndependent: true, summary: all, now: now)
    let events = rows.flatMap(\.events)
    try expect(!events.contains { $0.kind == .record })
    try expect(events.filter { $0.kind == .merge }.count == db.merges.count)
    try expect(events.filter { $0.kind == .start }.count == db.projects.count + db.branches.count)
    try expect(zip(rows, rows.dropFirst()).allSatisfy { $0.date >= $1.date })
    let branch = db.branches.first { $0.title == "交互设计" }!
    let expanded = db.roadmap(projectIDs: ids, collapsed: [], records: db.records, includeIndependent: true, summary: all.subtracting([branch.id]), now: now)
    try expect(expanded.flatMap(\.events).contains { $0.kind == .record && $0.laneID == branch.id })
    let project = db.projects[0]
    let folded = db.roadmap(projectIDs: ids, collapsed: [project.id], records: db.records, includeIndependent: true, summary: all, now: now)
    try expect(folded.flatMap(\.events).contains { $0.kind == .start && $0.laneID == project.id })
    try expect(folded.flatMap(\.events).contains { $0.kind == .merge && $0.laneID == project.id })
}

func relationPairsRemainDistinctAcrossTargetsAndDates() throws {
    var db = Workspace.demo()
    let child = db.branches.first { $0.originBranchID != nil }!
    let merge = MergeRecord(branchID: child.id, targetBranchID: child.originBranchID!, summary: "补充关系")
    db.merges.append(merge)
    let relations = db.routeRelations
    try expect(relations.count == Set(relations.map(\.id)).count)
    let fork = relations.first { $0.entityID == child.id }!
    try expect(fork.source == child.originBranchID && fork.target == child.id && fork.date == child.startAt)
    let pair = relations.first { $0.entityID == merge.id }!
    try expect(pair.source == child.id && pair.target == child.originBranchID && pair.kind == .merge)
    try expect(db.merges.allSatisfy { m in relations.contains { $0.entityID == m.id && $0.source == m.branchID && $0.target == m.targetLaneID } })
}

func expandedTimelineNeverLosesFutureOccurrences() throws {
    let db = Workspace()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let interval = DateInterval(start: now.addingTimeInterval(-86400 * 2200), end: now.addingTimeInterval(86400 * 365))
    var meeting = WorkRecord(kind: .meeting, title: "长期每日会议")
    meeting.startAt = now.addingTimeInterval(-86400 * 2000); meeting.endAt = meeting.startAt.addingTimeInterval(3600); meeting.repeatRule = .daily; meeting.timeZoneID = "UTC"
    let compact = db.timelineDates(of: meeting, in: interval, now: now, history: false)
    let expanded = db.timelineDates(of: meeting, in: interval, now: now, history: true)
    try expect(!compact.isEmpty && expanded.count > compact.count)
    try expect(Set(expanded).isSuperset(of: compact) && Set(expanded).count == expanded.count)
    var ongoing = WorkRecord(kind: .meeting, title: "正在进行")
    ongoing.startAt = now.addingTimeInterval(-1800); ongoing.endAt = now.addingTimeInterval(1800)
    try expect(db.timelineDates(of: ongoing, in: interval, now: now, history: false) == [ongoing.startAt])
    ongoing.endAt = now.addingTimeInterval(-300)
    try expect(db.timelineDates(of: ongoing, in: interval, now: now, history: false).isEmpty)
    let oldProgress = WorkRecord(title: "历史进度")
    let after = max(now, oldProgress.startAt).addingTimeInterval(86400)
    let range = DateInterval(start: oldProgress.startAt.addingTimeInterval(-86400), end: after.addingTimeInterval(86400))
    try expect(db.timelineDates(of: oldProgress, in: range, now: after, history: false).isEmpty)
    try expect(db.timelineDates(of: oldProgress, in: range, now: after, history: true) == [oldProgress.startAt])
}
