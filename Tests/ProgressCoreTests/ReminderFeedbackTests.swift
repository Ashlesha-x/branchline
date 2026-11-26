import Foundation
import ProgressCore

private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func weeklyFixture() -> (Workspace, WorkRecord) {
    var db = Workspace(); let p = Project(title: "提醒项目"); db.projects = [p]
    var meeting = WorkRecord(kind: .meeting, title: "每周回顾")
    meeting.projectIDs = [p.id]; meeting.timeZoneID = "Asia/Singapore"
    meeting.startAt = instant("2026-10-21T06:00:00Z"); meeting.endAt = meeting.startAt.addingTimeInterval(3600)
    meeting.repeatRule = .weekly; meeting.reminderDates = [meeting.startAt.addingTimeInterval(-900)]
    db.records = [meeting]; return (db, meeting)
}
func currentReminderDetailMatchesScheduledOccurrence() throws {
    let (_, meeting) = weeklyFixture()
    let event = instant("2026-10-28T06:00:00Z"), reminder = instant("2026-10-28T05:45:00Z")
    let detail = meeting.reminderSchedule(for: event)
    try expect(detail.count == 1 && detail[0].date == reminder && detail[0].occurrence == event)
    let queued = meeting.reminderSchedule(in: DateInterval(start: instant("2026-10-28T00:00:00Z"), end: instant("2026-10-29T00:00:00Z")))
    try expect(detail == queued)
    try expect(meeting.reminderDates == [instant("2026-10-21T05:45:00Z")])
}
func reminderPairingPreservesMonthEndLegacyAndRelativeRules() throws {
    var (_, meeting) = weeklyFixture()
    meeting.repeatRule = .monthly; meeting.startAt = instant("2026-01-30T16:05:00Z"); meeting.endAt = meeting.startAt.addingTimeInterval(3600)
    meeting.reminderDates = [meeting.startAt.addingTimeInterval(-900)]; meeting.relativeReminders = [.start15Minutes]
    let event = instant("2026-02-27T16:05:00Z")
    let detail = meeting.reminderSchedule(for: event)
    // Legacy fixed reminders retain their independent calendar anchor; no silent migration.
    try expect(detail.map(\.date) == [instant("2026-02-27T15:50:00Z"), instant("2026-02-28T15:50:00Z")])
    try expect(detail.allSatisfy { $0.occurrence == event })
    let queue = meeting.reminderSchedule(in: DateInterval(start: instant("2026-02-01T00:00:00Z"), end: instant("2026-03-02T00:00:00Z")))
    try expect(queue.filter { $0.occurrence == event } == detail)
    try expect(meeting.reminderSchedule(for: instant("2026-02-28T16:05:00Z")).isEmpty)
}
func reminderPairingHandlesDSTAndSplitAnchors() throws {
    var (db, meeting) = weeklyFixture()
    meeting.timeZoneID = "America/New_York"; meeting.startAt = instant("2026-03-01T14:00:00Z"); meeting.endAt = meeting.startAt.addingTimeInterval(3600)
    meeting.reminderDates = [instant("2026-03-01T13:45:00Z")]; meeting.relativeReminders = [.start15Minutes]
    db.records = [meeting]
    let event = instant("2026-03-08T13:00:00Z")
    let detail = meeting.reminderSchedule(for: event)
    try expect(detail.count == 1 && detail[0].date == instant("2026-03-08T12:45:00Z"))
    let split = try db.editingRecurring(meeting.id, occurrence: event, input: meeting.occurrenceDraft(at: event), scope: .following)
    let new = try require(split.records.first { $0.id != meeting.id })
    try expect(new.reminderSchedule(for: event) == detail)
    try expect(new.reminderSchedule(in: DateInterval(start: instant("2026-03-08T00:00:00Z"), end: instant("2026-03-09T00:00:00Z"))) == detail)
}
func notificationPayloadRoundTripResolvesExactSeriesDate() throws {
    let (db, meeting) = weeklyFixture(); let event = instant("2026-11-04T06:00:00Z")
    let target = ReminderNotificationTarget(recordID: meeting.id, occurrence: event)
    let parsed = try require(ReminderNotificationTarget(userInfo: target.userInfo))
    try expect(parsed == target)
    let destination = try require(db.reminderDestination(for: parsed))
    try expect(destination.recordID == meeting.id && destination.occurrence == event && destination.focusDate == event && destination.message == nil)
    let legacy = try require(ReminderNotificationTarget(userInfo: ["recordID": meeting.id.uuidString]))
    let old = try require(db.reminderDestination(for: legacy))
    try expect(old.occurrence == nil && old.focusDate == meeting.startAt && old.message != nil)
    try expect(ReminderNotificationTarget(userInfo: ["recordID": "invalid"]) == nil)
    try expect(ReminderNotificationTarget(userInfo: ["recordID": meeting.id.uuidString, "occurrenceStart": "bad"]) == nil)
}
func staleNotificationsRespectExceptionsDeletionAndRescheduling() throws {
    let (db, meeting) = weeklyFixture(); let event = instant("2026-10-28T06:00:00Z")
    let target = ReminderNotificationTarget(recordID: meeting.id, occurrence: event)
    var draft = meeting.occurrenceDraft(at: event); draft.startAt = draft.startAt.addingTimeInterval(86400); draft.endAt = draft.startAt.addingTimeInterval(3600)
    let edited = try db.editingRecurring(meeting.id, occurrence: event, input: draft, scope: .occurrence)
    let child = try require(edited.records.first { $0.seriesID == meeting.id })
    let moved = try require(edited.reminderDestination(for: target))
    try expect(moved.recordID == child.id && moved.occurrence == nil && moved.focusDate == draft.startAt && moved.message != nil)
    try expect(edited.record(meeting.id)!.reminderSchedule(for: event).isEmpty)
    try expect(edited.record(meeting.id)!.reminderSchedule(in: DateInterval(start: event.addingTimeInterval(-3600), end: event.addingTimeInterval(3600))).isEmpty)
    let canceled = try db.deletingRecurring(meeting.id, occurrence: event, scope: .occurrence)
    let fallback = try require(canceled.reminderDestination(for: target))
    try expect(fallback.recordID == meeting.id && fallback.occurrence == nil && fallback.message != nil)
    try expect(try db.deleting(.record(meeting.id)).reminderDestination(for: target) == nil)
    let split = try db.editingRecurring(meeting.id, occurrence: event, input: meeting.occurrenceDraft(at: event), scope: .following)
    try expect(split.reminderDestination(for: target)?.occurrence == nil && split.reminderDestination(for: target)?.message != nil)
}
func notificationDatesSurviveStoragePrecisionAndNonMeetingTargets() throws {
    var (db, meeting) = weeklyFixture()
    meeting.startAt = meeting.startAt.addingTimeInterval(0.7654321); meeting.endAt = meeting.startAt.addingTimeInterval(3600)
    db.records = [meeting]
    let event = meeting.startAt.addingTimeInterval(7 * 86400)
    let encoded = ReminderNotificationTarget(recordID: meeting.id, occurrence: event).userInfo
    let target = try require(ReminderNotificationTarget(userInfo: encoded))
    try expect(db.reminderDestination(for: target)?.occurrence == event)
    let restored = try Workspace.decoded(db.encoded())
    try expect(restored.reminderDestination(for: target)?.occurrence == target.occurrence)
    var task = WorkRecord(kind: .task, title: "任务"); task.projectIDs = [db.projects[0].id]; db.records.append(task)
    let destination = try require(db.reminderDestination(for: ReminderNotificationTarget(recordID: task.id, occurrence: event)))
    try expect(destination.occurrence == nil && destination.focusDate == task.startAt)
}
func todayAgendaReasonsComeFromTheInclusionConditions() throws {
    let (base, _) = weeklyFixture(); var db = base; db.records = []
    let now = instant("2026-10-28T02:00:00Z")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    func task(_ name: String) -> WorkRecord { var value = WorkRecord(kind: .task, title: name); value.projectIDs = [db.projects[0].id]; return value }
    var due = task("仅今天截止"); due.dueAt = instant("2026-10-28T08:00:00Z")
    var planned = task("计划覆盖今天，未来截止"); planned.taskScheduled = true; planned.startAt = instant("2026-10-27T00:00:00Z"); planned.endAt = instant("2026-10-30T00:00:00Z"); planned.dueAt = instant("2026-10-31T00:00:00Z")
    var both = planned; both.id = UUID(); both.title = "两项都满足"; both.dueAt = due.dueAt
    var absent = task("只有未来截止"); absent.dueAt = planned.dueAt
    var completed = due; completed.id = UUID(); completed.status = .completed
    db.records = [due, planned, both, absent, completed]
    let today = db.agenda(.today, now: now, calendar: calendar)
    try expect(Set(today.map { $0.record.id }) == [due.id, planned.id, both.id])
    try expect(today.first { $0.record.id == due.id }?.reasons == [.dueToday])
    try expect(today.first { $0.record.id == planned.id }?.reasons == [.plannedToday])
    try expect(today.first { $0.record.id == both.id }?.reasons == [.dueToday, .plannedToday])
    try expect(db.agenda(.week, now: now, calendar: calendar).allSatisfy { $0.reasons.isEmpty })
    try expect(!db.agenda(.today, now: instant("2026-10-28T16:00:00Z"), calendar: calendar).contains { $0.record.id == due.id })
}
