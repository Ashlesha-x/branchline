import Foundation
import ProgressCore

private func at(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private var singapore: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Singapore")!; return c }

func unifiedSearchIncludesAllEntities() throws {
    var db = Workspace.demo(now: at("2026-10-27T02:00:00Z"))
    db.projects[0].note += " ProjectNeedle"
    db.branches[0].note += " BranchNeedle"
    db.records[0].body += " RecordNeedle"
    db.merges[0].summary += " MergeNeedle"
    for (query, kind) in [("projectneedle", SearchEntity.project), ("BranchNeedle", .branch), ("RecordNeedle", .record), ("MergeNeedle", .merge)] {
        let hits = db.search("  \(query) \n")
        try expect(hits.count == 1 && hits[0].kind == kind)
    }
    try expect(db.search("完全不匹配654321").isEmpty)
    try expect(db.search(" \n ").isEmpty)
    let shared = try require(db.branches.first { $0.projectIDs.count > 1 })
    try expect(db.search(shared.title, projectID: shared.projectIDs[0]).filter { $0.id == shared.id }.count == 1)
    try expect(db.search(shared.title, projectID: shared.projectIDs[1]).contains { $0.id == shared.id })
    let merge = db.merges[0]
    try expect(db.search("MergeNeedle", projectID: merge.projectID).count == 1)
    let other = try require(db.projects.first { $0.id != merge.projectID && $0.id != db.branch(merge.targetBranchID)?.projectIDs.first })
    try expect(db.search("MergeNeedle", projectID: other.id).isEmpty)
    try expect(db.lockedProjectIDs(for: merge.branchID).contains(merge.projectID!))
}

func relativeRemindersTrackReschedulesAndRecurrences() throws {
    var meeting = WorkRecord(kind: .meeting, title: "月末会议")
    meeting.timeZoneID = "Asia/Singapore"; meeting.startAt = at("2026-01-31T00:05:00Z"); meeting.endAt = meeting.startAt.addingTimeInterval(3600)
    meeting.repeatRule = .monthly; meeting.relativeReminders = [.start15Minutes]
    let interval = DateInterval(start: at("2026-01-01T00:00:00Z"), end: at("2026-05-01T00:00:00Z"))
    let events = CalendarLogic.occurrences(of: meeting, in: interval)
    try expect(meeting.reminderOccurrences(in: interval) == events.map { $0.addingTimeInterval(-900) })
    meeting.repeatRule = .none
    let previous = meeting.reminderOccurrences(in: interval)[0]
    meeting.startAt = meeting.startAt.addingTimeInterval(86400)
    try expect(meeting.reminderOccurrences(in: interval) == [previous.addingTimeInterval(86400)])
    var task = WorkRecord(kind: .task, title: "仅日期截止")
    task.timeZoneID = "Asia/Singapore"; task.dueAt = at("2026-10-28T16:00:00Z"); task.relativeReminders = [.duePreviousDay9]
    try expect(RelativeReminder.duePreviousDay9.date(for: task) == at("2026-10-28T01:00:00Z"))
    let old = task; task.dueAt = task.dueAt?.addingTimeInterval(86400)
    try expect(task.rescheduleDelta(from: old) == 86400)
    try expect(old.reminderDates.isEmpty && task.reminderDates.isEmpty)
}

func reminderDaylightSavingAndHorizonBoundaries() throws {
    var meeting = WorkRecord(kind: .meeting, title: "DST")
    meeting.timeZoneID = "America/New_York"; meeting.startAt = at("2026-03-01T14:00:00Z"); meeting.endAt = meeting.startAt.addingTimeInterval(3600)
    meeting.repeatRule = .weekly; meeting.relativeReminders = [.start15Minutes, .start1Hour]
    let interval = DateInterval(start: at("2026-03-08T00:00:00Z"), end: at("2026-03-16T00:00:00Z"))
    try expect(meeting.reminderOccurrences(in: interval) == [at("2026-03-08T12:00:00Z"), at("2026-03-08T12:45:00Z"), at("2026-03-15T12:00:00Z"), at("2026-03-15T12:45:00Z")])
    meeting.repeatRule = .daily; meeting.startAt = at("2026-10-27T01:05:00Z"); meeting.endAt = meeting.startAt.addingTimeInterval(3600); meeting.relativeReminders = [.start15Minutes]
    try expect(meeting.reminderOccurrences(in: DateInterval(start: at("2026-10-27T00:45:00Z"), end: at("2026-10-27T01:00:00Z"))) == [at("2026-10-27T00:50:00Z")])
    try expect(meeting.reminderOccurrences(in: DateInterval(start: at("2026-10-26T00:00:00Z"), end: at("2026-10-26T23:00:00Z"))).isEmpty)
}

func agendaCoversSharedUndatedAndOvernightWork() throws {
    let now = at("2026-10-27T02:00:00Z")
    var db = Workspace.demo(now: now)
    let shared = try require(db.branches.first { $0.projectIDs.count > 1 })
    var task = WorkRecord(kind: .task, title: "没有日期"); task.branchID = shared.id
    task.createdAt = now.addingTimeInterval(-3600)
    db.records.append(task)
    try expect(db.search(task.title).first?.date == task.createdAt)
    let node = db.roadmap(projectIDs: Set(db.projects.map(\.id)), collapsed: [], records: [task], includeIndependent: true).flatMap(\.events).first { $0.entityID == task.id }
    try expect(node?.date == task.createdAt && node?.title == "任务录入 · " + task.title)
    try expect(db.agenda(.unscheduled, now: now, calendar: singapore).filter { $0.record.id == task.id }.count == 1)
    try expect(!db.agenda(.today, now: now, calendar: singapore).contains { $0.record.id == task.id })
    task.taskScheduled = true; task.startAt = at("2026-10-25T02:00:00Z"); task.endAt = at("2026-10-29T02:00:00Z")
    db.records[db.records.count - 1] = task
    try expect(db.agenda(.today, now: now, calendar: singapore).filter { $0.record.id == task.id }.count == 1)
    task.endAt = nil; db.records[db.records.count - 1] = task
    try expect(db.agenda(.today, now: now, calendar: singapore).contains { $0.record.id == task.id })
    var meeting = WorkRecord(kind: .meeting, title: "跨夜"); meeting.projectIDs = [db.projects[0].id]; meeting.timeZoneID = "Asia/Singapore"
    meeting.startAt = at("2026-10-26T15:30:00Z"); meeting.endAt = at("2026-10-26T17:00:00Z"); meeting.repeatRule = .daily
    db.records.append(meeting)
    let today = db.agenda(.today, now: now, calendar: singapore).filter { $0.record.id == meeting.id }
    try expect(today.count == 2 && today.first?.date == meeting.startAt)
    try expect(db.agenda(.week, now: now, calendar: singapore).filter { $0.record.id == meeting.id }.count == 8)
    let blocked = db.agenda(.blocked, now: now, calendar: singapore)
    try expect(blocked.allSatisfy { !db.blockedBy($0.record).isEmpty })
    try expect(db.agenda(.overdue, now: now, calendar: singapore).allSatisfy { CalendarLogic.deadlinePassed($0.record, now: now) })
}

func legacyWorkflowFieldsAndNewRulesRoundTrip() throws {
    var db = Workspace.demo(now: at("2026-10-27T02:00:00Z"))
    let original = db.records[0].reminderDates
    var raw = try JSONSerialization.jsonObject(with: db.encoded()) as! [String: Any]
    var records = raw["records"] as! [[String: Any]]
    for i in records.indices { records[i].removeValue(forKey: "taskScheduled"); records[i].removeValue(forKey: "relativeReminders") }
    raw["records"] = records
    let legacy = try Workspace.decoded(JSONSerialization.data(withJSONObject: raw))
    try expect(legacy.records[0].reminderDates == original)
    try expect(legacy.records.allSatisfy { $0.relativeRules.isEmpty && $0.hasPlannedStart })
    let i = try require(db.records.firstIndex { $0.kind == .meeting })
    db.records[i].relativeReminders = [.start15Minutes]
    let restored = try Workspace.decoded(db.encoded())
    try expect(restored.records[i].relativeRules == [.start15Minutes])
    db.records[i].relativeReminders = [.duePreviousDay9]
    try expectThrows { try db.validate() }
}

func meetingTimeTextPreservesDatesAndZone() throws {
    var meeting = WorkRecord(kind: .meeting, title: "时刻")
    meeting.timeZoneID = "Asia/Singapore"; meeting.startAt = at("2026-10-29T06:00:00Z"); meeting.endAt = at("2026-10-29T07:00:00Z")
    try expect(WorkDateText.meeting(meeting) == "2026年10月29日 14:00–15:00")
    meeting.endAt = at("2026-10-29T17:00:00Z")
    try expect(WorkDateText.meeting(meeting) == "2026年10月29日 14:00–2026年10月30日 01:00")
    try expect(WorkDateText.meeting(meeting, occurrence: at("2026-11-01T06:00:00Z")) == "2026年11月1日 14:00–2026年11月2日 01:00")
}
