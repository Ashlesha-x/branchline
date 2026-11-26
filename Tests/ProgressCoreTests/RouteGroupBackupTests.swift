import Foundation
import ProgressCore

func rootOrderMovesIndependentRoutesWithoutReparenting() throws {
    let db = Workspace.demo(), before = try db.encoded()
    let roots = db.routePlacements(projectIDs: db.projects.map(\.id)).filter { db.project($0.id) != nil || ($0.ownerProjectID == nil && $0.depth == 0) }.map(\.id)
    let independent = db.branches.first { db.branchIsIndependent($0.id) && $0.originBranchID == nil }!.id
    let project = db.projects.first { $0.status == .active }!.id
    let order = RouteGroups.reordered(roots, moving: independent, to: project, after: false)
    let layout = db.presentedRoutes(projectIDs: db.projects.map(\.id), rootOrder: order)
    try expect(layout.first!.id == independent)
    let parent = db.branches.first { $0.title == "交互设计" }!.id
    let child = db.branches.first { $0.originBranchID == parent }!.id
    try expect(layout.firstIndex { $0.id == child }! == layout.firstIndex { $0.id == parent }! + 1)
    try expect(try db.encoded() == before)
    try expect(RouteGroups.reordered(roots, moving: UUID(), to: project, after: false) == roots)
    let reversed = db.presentedRoutes(projectIDs: db.projects.map(\.id), rootOrder: [independent, independent, UUID()])
    try expect(reversed.first?.id == independent && Set(reversed.map(\.id)).count == reversed.count)
}

func inactiveProjectGroupsFoldAndRetainTheirOwnRoutes() throws {
    let db = Workspace.demo(), ids = db.projects.map(\.id)
    let folded = db.presentedRoutes(projectIDs: ids)
    try expect(folded.compactMap(\.groupStatus) == RouteGroups.statuses)
    try expect(folded.suffix(3).allSatisfy { $0.groupStatus != nil })
    try expect(!folded.contains { db.project($0.id).map { $0.status != .active } == true })
    let expanded = db.presentedRoutes(projectIDs: ids, expandedStatuses: [.paused])
    let paused = db.projects.first { $0.status == .paused }!
    try expect(expanded.contains { $0.id == paused.id })
    try expect(!expanded.contains { db.project($0.id)?.status == .completed })
    let all = db.presentedRoutes(projectIDs: ids, expandedStatuses: Set(RouteGroups.statuses))
    try expect(Set(all.filter { $0.groupStatus == nil }.map(\.id)).count == db.projects.count + db.branches.count)
    let rows = db.presentedRoadmap(projectIDs: ids, collapsed: [], records: db.records, includeIndependent: true, summary: [], layout: all)
    let headers = rows.filter { $0.events.first?.kind == .statusGroup }
    try expect(headers.map(\.laneID) == RouteGroups.statuses.map(RouteGroups.id))
    for (i, status) in RouteGroups.statuses.enumerated() {
        let begin = rows.firstIndex { $0.laneID == RouteGroups.id(status) }! + 1
        let end = i + 1 < RouteGroups.statuses.count ? rows.firstIndex { $0.laneID == RouteGroups.id(RouteGroups.statuses[i + 1]) }! : rows.count
        let dates = rows[begin..<end].map(\.date)
        try expect(dates == dates.sorted(by: >))
    }
    let hiddenRows = db.presentedRoadmap(projectIDs: ids, collapsed: [], records: db.records, includeIndependent: true, summary: [], layout: folded)
    try expect(!hiddenRows.contains { db.project($0.laneID).map { $0.status != .active } == true })
    let target = db.projects.first { $0.status == .completed }!
    let scoped = db.presentedRoutes(projectIDs: [target.id], includeIndependent: false)
    try expect(scoped.count == 1 && scoped.first?.groupStatus == .completed)
}

func dailyBackupsRespectDirtyDaysAndCatchUp() throws {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Singapore")!
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))! }
    func due(_ now: Date, _ last: Date? = nil, _ enabled: Date? = nil, _ dirty: Bool = true) -> Bool {
        DailyBackupSchedule.shouldBackup(now: now, lastSuccess: last, enabledSince: enabled ?? date(29, 10), minuteOfDay: 1200, hasChanges: dirty, calendar: cal)
    }
    try expect(!due(date(29, 19, 59)))
    try expect(due(date(29, 20)))
    try expect(!due(date(29, 21), nil, date(29, 10), false))
    try expect(!due(date(29, 22), date(29, 20)))
    try expect(due(date(30, 9))) // yesterday's missed run
    try expect(!due(date(30, 9), nil, date(30, 8))) // first enable waits for today
    try expect(due(date(30, 21), nil, date(30, 21)))
    try expect(!due(date(30, 21), date(30, 9))) // catch-up counts as today's run
    try expect(due(date(30, 21), date(29, 20)))
    try expect(!DailyBackupSchedule.shouldBackup(now: date(30, 21), lastSuccess: nil, enabledSince: date(29, 10), minuteOfDay: 1440, hasChanges: true, calendar: cal))
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    let beforeDST = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 20))!
    let afterDST = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 20))!
    try expect(DailyBackupSchedule.shouldBackup(now: afterDST, lastSuccess: beforeDST, enabledSince: beforeDST, minuteOfDay: 1200, hasChanges: true, calendar: cal))
}
