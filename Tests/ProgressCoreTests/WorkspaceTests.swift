import Foundation
import ProgressCore

private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

func demoIsValidAndSharedBranchIsUnique() throws {
    let db = Workspace.demo(now: instant("2026-10-26T02:00:00Z"))
    try db.validate()
    let shared = try require(db.branches.first { $0.projectIDs.count == 2 })
    try expect(db.branches.filter { $0.id == shared.id }.count == 1)
    try expect(Set(db.merges.filter { $0.branchID == shared.id }.map(\.projectID)).count == 2)
    try expect(db.projects(for: try require(db.records.first { $0.branchID == shared.id })) == shared.projectIDs)
    try expect(Set(db.projects.map(\.status)) == Set(WorkStatus.allCases))
    try expect(db.branches.contains { $0.projectIDs.isEmpty })
    try expect(db.branches.contains { $0.originBranchID != nil })
    try expect(db.merges.contains { $0.targetBranchID != nil })
    try expect(db.merges.contains { $0.closesBranch })
    try expect(db.records.contains { !$0.dependencies.isEmpty })
    try expect(db.records.contains { $0.kind == .task && $0.endAt == nil && $0.dueAt != nil })
    try expect(db.records.contains { $0.kind == .task && $0.status == .completed })
    try expect(db.records.contains { CalendarLogic.deadlinePassed($0, now: instant("2026-10-26T02:00:00Z")) })
    try expect(Set(db.records.filter { $0.kind == .meeting }.map(\.repeatRule)) == Set(RepeatRule.allCases))
    try expect(db.records.contains { $0.projectIDs.count > 1 && $0.branchID == nil })
    try expect(db.records.contains { !$0.reminderDates.isEmpty })
    try expect(!db.history.isEmpty)
}

func backupPreservesLinksAndImmutableMergeSummary() throws {
    var db = Workspace.demo(now: instant("2026-10-26T02:00:00Z"))
    let summary = try require(db.merges.first).summary
    let sourceID = try require(db.merges.first?.sourceRecordIDs.first)
    let index = try require(db.records.firstIndex { $0.id == sourceID })
    db.records[index].body = "后来更新的来源文字"
    let restored = try Workspace.decoded(db.encoded())
    try expect(restored.merges.first?.summary == summary)
    try expect(restored.merges.first?.sourceRecordIDs == db.merges.first?.sourceRecordIDs)
    try expect(restored.records[index].body == "后来更新的来源文字")
    try expect(try restored.encoded() == db.encoded())
}

func dependencyCycleIsRejectedAcrossBranches() throws {
    var db = Workspace.demo()
    let taskIndices = db.records.indices.filter { db.records[$0].kind == .task }
    let a = taskIndices[0], b = taskIndices[1]
    db.records[a].dependencies = [db.records[b].id]
    try db.validate()
    db.records[b].dependencies = [db.records[a].id]
    try expectThrows { try db.validate() }
}

func invalidBackupCannotLeaveDanglingReferences() throws {
    var db = Workspace.demo()
    db.branches[0].projectIDs = [UUID()]
    try expectThrows { try db.validate() }
    db = .demo(); db.version = 99
    try expectThrows { _ = try db.encoded() }
    db = .demo(); db.projects[1].id = db.projects[0].id
    try expectThrows { try db.validate() }
}

func datesAllowOpenEndedTasksButRejectReverseIntervals() throws {
    var db = Workspace.demo()
    let index = try require(db.records.firstIndex { $0.kind == .task })
    db.records[index].startAt = instant("2027-01-01T02:00:00Z")
    db.records[index].endAt = nil; db.records[index].dueAt = nil
    try db.validate()
    db.records[index].endAt = instant("2026-01-01T02:00:00Z")
    try expectThrows { try db.validate() }
}

func dateOnlyDeadlineExpiresAfterItsLocalDay() throws {
    var record = WorkRecord(kind: .task, title: "交付")
    record.timeZoneID = "Asia/Singapore"
    record.dueAt = instant("2026-10-26T01:00:00Z"); record.dueDateOnly = true
    try expect(!CalendarLogic.deadlinePassed(record, now: instant("2026-10-26T15:59:59Z")))
    try expect(CalendarLogic.deadlinePassed(record, now: instant("2026-10-26T16:00:00Z")))
    record.status = .completed
    try expect(!CalendarLogic.deadlinePassed(record, now: instant("2026-10-27T16:00:00Z")))
}

func recurringMeetingKeepsWallClockAcrossDaylightSaving() throws {
    var meeting = WorkRecord(kind: .meeting, title: "每周会议")
    meeting.startAt = instant("2026-03-01T14:00:00Z")
    meeting.timeZoneID = "America/New_York"; meeting.repeatRule = .weekly
    let dates = CalendarLogic.occurrences(of: meeting, in: DateInterval(start: instant("2026-03-01T00:00:00Z"), end: instant("2026-03-16T00:00:00Z")))
    try expect(dates == [instant("2026-03-01T14:00:00Z"), instant("2026-03-08T13:00:00Z"), instant("2026-03-15T13:00:00Z")])
}

func recurrenceCanJumpYearsWithoutLosingFirstVisibleOccurrence() throws {
    var meeting = WorkRecord(kind: .meeting, title: "每日会议")
    meeting.startAt = instant("2020-01-01T01:00:00Z"); meeting.timeZoneID = "Asia/Singapore"; meeting.repeatRule = .daily
    let dates = CalendarLogic.occurrences(of: meeting, in: DateInterval(start: instant("2026-10-26T00:00:00Z"), end: instant("2026-10-29T00:00:00Z")))
    try expect(dates.count == 3)
    try expect(dates.first == instant("2026-10-26T01:00:00Z"))
}

@MainActor func persistenceSurvivesRepositoryRecreationAndRejectsBadWrites() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("branchline-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("workspace.store")
    let db = Workspace.demo(now: instant("2026-10-26T02:00:00Z"))
    do { let first = try WorkspaceRepository(url: url); try first.save(db) }
    let second = try WorkspaceRepository(url: url)
    let loaded = try require(second.load())
    try expect(try loaded.encoded() == db.encoded())
    var invalid = db; invalid.projects[0].title = "  "
    try expectThrows { try second.save(invalid) }
    try expect(try second.load()?.encoded() == db.encoded())
}

@MainActor func demoAndPersonalRepositoriesAreIsolated() throws {
    let personal = try WorkspaceRepository(inMemory: true), demo = try WorkspaceRepository(inMemory: true)
    try personal.save(Workspace()); try demo.save(.demo())
    try expect(try personal.load()?.projects.isEmpty == true)
    try expect(try demo.load()?.projects.count == 5)
}

func closureDatesRespectLatestMerge() throws {
    let original = Workspace.demo(now: instant("2026-10-26T02:00:00Z"))
    let branchIndex = try require(original.branches.firstIndex { $0.projectIDs.count == 2 })
    let latest = try require(original.merges.map(\.date).max())
    for archived in [false, true] {
        var db = original
        db.branches[branchIndex].status = archived ? .archived : .completed
        if archived { db.branches[branchIndex].archivedAt = latest.addingTimeInterval(-86_400) }
        else { db.branches[branchIndex].closedAt = latest.addingTimeInterval(-86_400) }
        try expectThrows { try db.validate() }
        // Date-only controls allow a closure earlier in the same civil day.
        if archived { db.branches[branchIndex].archivedAt = Calendar.current.startOfDay(for: latest) }
        else { db.branches[branchIndex].closedAt = Calendar.current.startOfDay(for: latest) }
        try db.validate()
        let target = try require(db.projects.firstIndex { $0.id == db.merges.last?.projectID })
        if archived { db.projects[target].archivedAt = latest.addingTimeInterval(-86_400) }
        else { db.projects[target].closedAt = latest.addingTimeInterval(-86_400) }
        try expectThrows { _ = try db.encoded() }
    }
    var db = original
    db.branches[branchIndex].closedAt = latest
    db.branches[branchIndex].archivedAt = latest.addingTimeInterval(-86_400)
    try expectThrows { try db.validate() }
}

func legacyBackupWithoutClosureDates() throws {
    let original = Workspace.demo()
    let data = try original.encoded()
    var object = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["projects", "branches"] {
        object[key] = (object[key] as? [[String: Any]])?.map { value in
            var copy = value; copy.removeValue(forKey: "closedAt"); copy.removeValue(forKey: "archivedAt"); return copy
        }
    }
    let decoded = try Workspace.decoded(JSONSerialization.data(withJSONObject: object))
    try expect(decoded.projects.count == original.projects.count)
    try expect(decoded.projects.allSatisfy { $0.archivedAt == nil && $0.closedAt == nil })
}

func routeColorsAvoidOccupiedAndReleaseArchived() throws {
    try expect(RouteColors.swatchIDs.count == 64)
    try expect(Set(RouteColors.swatchIDs).count == 64)
    try expect(RouteColors.swatchIDs.allSatisfy(RouteColors.isValid))
    let quantized = RouteColors.swatchIDs.map { id -> String in
        let c = RouteColors.rgb(id)
        return [c.0, c.1, c.2].map { String(Int(($0 * 255).rounded())) }.joined(separator: ",")
    }
    try expect(Set(quantized).count == 64)
    for column in 0..<8 {
        var previous = 0.0
        for row in 0..<8 {
            let c = RouteColors.rgb(RouteColors.swatchIDs[row * 8 + column])
            let brightness = 0.30 * c.0 + 0.59 * c.1 + 0.11 * c.2
            try expect(brightness > previous + 0.025)
            previous = brightness
        }
    }
    try expect(RouteColors.rgb(0).0 == 0.05)
    try expect(RouteColors.rgb(12).0 == 0.12)

    var db = Workspace()
    for n in 0..<70 {
        let used = db.occupiedRouteColors()
        let color = db.availableRouteColor()
        try expect(!used.contains(color))
        db.projects.append(Project(title: "P\(n)", color: color))
    }
    try db.validate()
    let released = db.projects[0].color
    db.projects[0].status = .archived
    try expect(!db.occupiedRouteColors().contains(released))
    db.projects[0].status = .paused
    try expect(db.occupiedRouteColors().contains(released))
    var branch = Branch(title: "共享", projectIDs: Array(db.projects.prefix(2).map(\.id)))
    branch.color = db.availableRouteColor()
    try expect(!db.projects.prefix(2).map(\.color).contains(branch.color))
    db.branches.append(branch)
    try expect(db.occupiedRouteColors().contains(branch.color))
}

func roadmapPreservesRoutesAndGroupsRecords() throws {
    var db = Workspace.demo(now: instant("2026-10-26T02:00:00Z"))
    let shared = try require(db.branches.first { $0.projectIDs.count == 2 })
    let original = try require(db.records.first { $0.branchID == shared.id })
    var extra = original; extra.id = UUID(); extra.title = "同日补记"; db.records.append(extra)
    let visible = Set(db.projects.map(\.id))
    let rows = db.roadmap(projectIDs: visible, collapsed: [], records: db.records, includeIndependent: true)
    let events = rows.flatMap(\.events)
    try expect(rows.contains { $0.events.count == 2 })
    try expect(events.filter { $0.kind == .merge }.count == db.merges.count)
    try expect(events.filter { $0.kind == .start }.count == db.projects.count + db.branches.count)
    try expect(Set(events.map(\.id)).count == events.count)
    try expect(zip(rows, rows.dropFirst()).allSatisfy { $0.date >= $1.date })
    let partial = db.roadmap(projectIDs: visible, collapsed: [shared.projectIDs[0]], records: db.records, includeIndependent: true)
    try expect(partial.contains { $0.laneID == shared.id })
    let folded = db.roadmap(projectIDs: visible, collapsed: Set(shared.projectIDs), records: db.records, includeIndependent: true)
    try expect(!folded.contains { $0.laneID == shared.id })
    try expect(!folded.contains { shared.projectIDs.contains($0.laneID) })
    let allHidden = db.roadmap(projectIDs: Set(shared.projectIDs), collapsed: Set(shared.projectIDs), records: db.records, includeIndependent: false)
    try expect(allHidden.isEmpty)
    let archived = try require(db.projects.first { $0.status == .archived })
    let before = db.roadmap(projectIDs: visible, collapsed: [archived.id], records: db.records, includeIndependent: true)
    db.projects[db.projects.firstIndex { $0.id == archived.id }!].createdAt = instant("1990-01-01T00:00:00Z")
    let after = db.roadmap(projectIDs: visible, collapsed: [archived.id], records: db.records, includeIndependent: true)
    try expect(before.map(\.id) == after.map(\.id))
    try expect(before.map(\.date) == after.map(\.date))
}
