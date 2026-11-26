import Foundation
import ProgressCore

private func op(_ action: String, _ entity: String, _ key: String, _ fields: [String: JSONValue]) -> JSONValue {
    .object(["action": .string(action), "entity": .string(entity), action == "create" ? "ref" : "id": .string(key), "fields": .object(fields)])
}
private func request(_ w: Workspace, _ ops: [JSONValue]) -> JSONValue {
    .object(["requestID": .string(UUID().uuidString), "expectedRevision": .string(w.automationRevision), "operations": .array(ops)])
}
private func branchWorkspace() throws -> Workspace {
    let w = Workspace()
    return try AutomationAPI.plan(request(w, [op("create", "project", "p", ["title": .string("修复检查")]), op("create", "branch", "b", ["title": .string("分支"), "projectIDs": .array([.string("$p")]), "originProjectID": .string("$p")]), op("create", "record", "r", ["kind": .string("task"), "title": .string("任务"), "branchID": .string("$b")])]), in: w).workspace
}
private func zoned(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c }

/// Day-order checks: strict uses the current calendar day; loose tolerates any time zone shift.
func dayOrderToleratesTimeZoneChanges() throws {
    let iso = ISO8601DateFormatter()
    // 2026-11-01 01:00 in Singapore is still 2026-10-31 in Los Angeles.
    let earlier = iso.date(from: "2026-10-31T17:00:00Z")!, later = iso.date(from: "2026-10-31T10:00:00Z")!
    try expect(Workspace.dayNotBefore(later, earlier, strict: true, calendar: zoned("America/Los_Angeles")))
    try expect(!Workspace.dayNotBefore(later, earlier, strict: true, calendar: zoned("Asia/Singapore")))
    try expect(Workspace.dayNotBefore(later, earlier, strict: false, calendar: zoned("Asia/Singapore")))
    try expect(!Workspace.dayNotBefore(earlier.addingTimeInterval(-86_400), earlier, strict: false, calendar: zoned("Asia/Singapore")))
}

func trashRetentionAndPermanentDelete() throws {
    var w = try branchWorkspace()
    w = try w.deleting(.record(w.records[0].id))
    let entry = try require(w.trash.first)
    var aged = w
    try expect(!aged.pruneExpired(now: entry.deletedAt.addingTimeInterval(86_400 * 29)))
    try expect(aged.pruneExpired(now: entry.deletedAt.addingTimeInterval(86_400 * 31)))
    try expect(aged.trash.isEmpty && (aged.automationReceipts ?? []).isEmpty)
    let purged = try w.purgingTrash(entry.id)
    try expect(purged.trash.isEmpty && purged.records.isEmpty)
    try expectThrows { _ = try purged.purgingTrash(entry.id) }
}

/// Saving rounds dates to whole seconds; a restore after reopening must still match.
func trashRestoreSurvivesReopen() throws {
    var w = try branchWorkspace()
    w.records[0].startAt = Date(timeIntervalSince1970: 1_790_000_000.375)
    w.records[0].dueAt = Date(timeIntervalSince1970: 1_790_003_600.625)
    w = try w.deleting(.record(w.records[0].id))
    let reopened = try Workspace.decoded(w.encoded())
    let restored = try reopened.restoringTrash(try require(reopened.trash.first).id)
    try expect(restored.records.count == 1 && restored.trash.isEmpty)
}

func automationRejectsConflictingLocation() throws {
    let w = try branchWorkspace()
    let id = w.records[0].id.uuidString
    do {
        _ = try AutomationAPI.plan(request(w, [op("update", "record", id, ["projectIDs": .array([.string(w.projects[0].id.uuidString)])])]), in: w)
        throw CheckFailure(description: "conflicting_location was not raised")
    } catch let error as WorkspaceError { try expect(error.message.hasPrefix("conflicting_location")) }
    let moved = try AutomationAPI.plan(request(w, [op("update", "record", id, ["branchID": .null, "projectIDs": .array([.string(w.projects[0].id.uuidString)])])]), in: w).workspace
    try expect(moved.records[0].branchID == nil && moved.records[0].projectIDs == [w.projects[0].id])
}

/// Completion order inside one batch does not matter; only the final state is checked.
func automationBatchCompletionOrderIndependent() throws {
    var w = try branchWorkspace()
    var task = WorkRecord(kind: .task, title: "后续"); task.branchID = w.branches[0].id; task.dependencies = [w.records[0].id]; w.records.append(task)
    let done = try AutomationAPI.plan(request(w, [op("update", "record", task.id.uuidString, ["status": .string("completed")]), op("update", "record", w.records[0].id.uuidString, ["status": .string("completed")])]), in: w).workspace
    try expect(done.records.allSatisfy { $0.status == .completed })
}

func automationDateOnlyDueKeepsDay() throws {
    let w = try branchWorkspace()
    let zone = w.records[0].timeZoneID
    let next = try AutomationAPI.plan(request(w, [op("update", "record", w.records[0].id.uuidString, ["dueAt": .string("2026-12-01T00:00:00Z"), "dueDateOnly": .bool(true)])]), in: w).workspace
    let due = try require(next.records[0].dueAt)
    try expect(due == WorkRecord.dateOnlyAnchor(due, timeZoneID: zone))
    let anchor = WorkRecord.dateOnlyAnchor(ISO8601DateFormatter().date(from: "2026-11-30T20:00:00Z")!, timeZoneID: "Asia/Singapore")
    try expect(zoned("Asia/Singapore").component(.hour, from: anchor) == 12 && zoned("Asia/Singapore").component(.day, from: anchor) == 1)
}

@MainActor func recurringCatchUpAddsOnlyLatestMissed() throws {
    var db = Workspace.demo()
    let now = Date()
    var task = WorkRecord(kind: .task, title: "每日检查"); task.projectIDs = [db.projects[0].id]; task.startAt = now.addingTimeInterval(-1); task.dueAt = now; task.taskRepeatRule = .daily
    try db.createTaskPlan(from: task, now: now)
    let before = db.records.count
    let later = now.addingTimeInterval(86_400 * 60)
    try expect(db.materializeTaskPlans(now: later))
    let today = Calendar.current.startOfDay(for: later)
    let id = try require(db.taskPlans?.first?.id)
    let stale = db.records.dropFirst(before).filter { $0.taskSeriesID == id && ($0.taskOccurrence ?? later) < today.addingTimeInterval(-86_400 * 2) }
    try expect(stale.count <= 1)
}

func occurrencesIgnoreSystemCalendarKind() throws {
    var meeting = WorkRecord(kind: .meeting, title: "周会"); meeting.repeatRule = .weekly
    meeting.timeZoneID = "Asia/Singapore"; meeting.startAt = ISO8601DateFormatter().date(from: "2026-11-02T02:00:00Z")!
    var chinese = Calendar(identifier: .chinese); chinese.timeZone = TimeZone(identifier: "Asia/Singapore")!
    let interval = DateInterval(start: meeting.startAt, duration: 86_400 * 28)
    let dates = CalendarLogic.occurrences(of: meeting, in: interval, calendar: chinese)
    try expect(dates == CalendarLogic.occurrences(of: meeting, in: interval, calendar: zoned("Asia/Singapore")))
    try expect(dates.count == 4 && zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 7 * 86_400 })
}
