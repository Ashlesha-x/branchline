import Foundation
import ProgressCore

@MainActor func reviewEditsUndoAndMigrationSurviveReopen() throws {
    let db = Workspace.demo(), now = Date()
    let report = try db.review(from: now, through: now, projectID: nil, branchID: nil)
    var draft = ReviewDraft(preset: "自定义", from: now, through: now)
    draft.replace(with: report); try expect(!draft.hasManualChanges)
    draft.text += "\n手工润色后的关键结论。"; try expect(draft.hasManualChanges)
    let polished = draft.text
    draft.replace(with: report); try expect(draft.previous?.text == polished && !draft.hasManualChanges)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID())/draft.json")
    let repo = ReviewDraftRepository(url: url); try repo.save(draft)
    var restored = try require(repo.load()); restored.undoReplacement()
    try expect(restored.text == polished && restored.hasManualChanges && restored.previous == nil)
    let backup = try MigrationBackup.decoded(MigrationBackup(workspace: db, drafts: [], review: restored).encoded())
    try expect(backup.review?.text == polished && backup.includesReview)
    let old = try MigrationBackup.decoded(db.encoded()); try expect(!old.includesReview)
    let oldEnvelope: [String: Any] = ["format": "branchline.migration", "version": 1, "workspace": try JSONSerialization.jsonObject(with: db.encoded()), "drafts": []]
    try expect(!MigrationBackup.decoded(JSONSerialization.data(withJSONObject: oldEnvelope)).includesReview)
    try repo.save(restored)
    let before = MigrationBackup(workspace: db, drafts: [], review: restored)
    let target = MigrationBackup(workspace: db, drafts: [], review: draft)
    var failed = false
    do {
        try MigrationRestoreJournal(url: url.appendingPathExtension("journal")).apply(target, previous: before, saveWorkspace: { _ in
            if !failed { failed = true; throw WorkspaceError("一次写入失败") }
        }, saveDrafts: { _ in }, saveReview: { try repo.save($0) })
        throw CheckFailure(description: "Failed restore accepted")
    } catch let error as MigrationRestoreFailure { try expect(!error.recoveryRequired) }
    try expect(repo.load()?.text == polished)
}

@MainActor func reviewSeparatesPastAndFutureMeetings() throws {
    var db = Workspace.demo(); let now = Date()
    var past = WorkRecord(kind: .meeting, title: "已开会"); past.projectIDs = [db.projects[0].id]; past.startAt = now.addingTimeInterval(-3600); past.endAt = now.addingTimeInterval(-1800)
    var future = past; future.id = UUID(); future.title = "后续安排"; future.startAt = now.addingTimeInterval(86400); future.endAt = future.startAt.addingTimeInterval(3600)
    db.records = [past, future]
    let result = try db.review(from: now.addingTimeInterval(-86400), through: now.addingTimeInterval(86400 * 3), projectID: nil, branchID: nil, now: now)
    try expect(result.sections.first { $0.title == "已发生会议" }?.entries.map(\.entityID) == [past.id])
    try expect(result.sections.first { $0.title == "后续会议安排" }?.entries.map(\.entityID) == [future.id])
}

@MainActor func followingTasksPreserveHistoryIdentityAndNotes() throws {
    let f = ISO8601DateFormatter(); let friday = f.date(from: "2026-11-06T10:00:00Z")!
    var db = Workspace.demo()
    var task = WorkRecord(kind: .task, title: "每周五检查"); task.projectIDs = [db.projects[0].id]; task.startAt = friday.addingTimeInterval(-86400); task.taskScheduled = true; task.dueAt = friday; task.timeZoneID = "UTC"; task.taskRepeatRule = .weekly
    try db.createTaskPlan(from: task, now: friday)
    let originalPlan = try require(db.taskPlans?.first)
    let instances = db.records.filter { $0.taskSeriesID == originalPlan.id }.sorted { $0.taskOccurrence! < $1.taskOccurrence! }
    var done = instances[0]; done.status = .completed; done.completedAt = friday; try db.putRecord(done, now: friday)
    let historical = try require(db.record(done.id))
    var note = instances[2]; note.body = "仅这次需要换滤芯"; try db.putRecord(note)
    var input = instances[1]; input.title = "改周四检查"; input.dueAt = input.dueAt!.addingTimeInterval(-86400); input.projectIDs = [db.projects[1].id]
    let next = try db.editingTaskPlan(input, scope: .following, now: friday)
    try expect(next.record(historical.id) == historical)
    try expect(next.record(note.id)?.body == "仅这次需要换滤芯")
    try expect(next.record(note.id)?.dueAt == instances[2].dueAt!.addingTimeInterval(-86400))
    try expect(next.record(note.id)?.startAt == instances[2].startAt)
    try expect(next.record(note.id)?.projectIDs == input.projectIDs)
    try expect(next.taskFamilyID(for: next.record(note.id)!) == originalPlan.id)
    try expect(!next.materializedCopyChanges(now: friday))
    let single = try db.editingTaskPlan(input, scope: .occurrence, now: friday)
    try expect(single.record(note.id)?.dueAt == note.dueAt && single.taskPlans?.count == 1)
    var unscheduled = input; unscheduled.taskScheduled = false; unscheduled.endAt = nil; unscheduled.dueAt = nil; unscheduled.taskRepeatRule = RepeatRule.none
    let stopped = try db.editingTaskPlan(unscheduled, scope: .following, now: friday)
    try expect(stopped.record(input.id)?.taskSeriesID == nil && stopped.record(input.id)?.dueAt == nil)
    try expect(stopped.record(historical.id) == historical)
}

private extension Workspace {
    func materializedCopyChanges(now: Date) throws -> Bool { var copy = self; return try copy.materializeTaskPlans(now: now) }
}

@MainActor func followingFrequencyChangeDoesNotRegenerateCompletedSlots() throws {
    let now = Date(); var db = Workspace.demo()
    var task = WorkRecord(kind: .task, title: "周期任务"); task.projectIDs = [db.projects[0].id]; task.dueAt = now; task.taskRepeatRule = .weekly
    try db.createTaskPlan(from: task, now: now)
    var done = try require(db.record(task.id)); done.status = .completed; done.completedAt = now; try db.putRecord(done, now: now)
    let saved = try require(db.record(done.id)); var input = saved; input.taskRepeatRule = .daily; input.title = "改为每天"
    var ahead = try require(db.records.filter { $0.taskSeriesID == saved.taskSeriesID }.sorted { $0.taskOccurrence! < $1.taskOccurrence! }.dropFirst(2).first)
    ahead.status = .completed; ahead.completedAt = now; try db.putRecord(ahead, now: now)
    let next = try db.editingTaskPlan(input, scope: .following, now: now)
    try expect(next.record(done.id) == saved)
    let replacement = try require(next.taskPlans?.last)
    try expect(replacement.excluded.contains(now))
    try expect(!next.records.contains { $0.taskSeriesID == replacement.id && $0.taskOccurrence == now })
    try expect(next.records.filter { $0.taskSeriesID == replacement.id }.count > 20)
    let secondDay = Calendar.current.date(byAdding: .day, value: 2, to: now)!
    try expect(next.records.contains { $0.taskSeriesID == replacement.id && Calendar.current.isDate($0.taskOccurrence!, inSameDayAs: secondDay) })
    try expect(!next.records.contains { $0.taskSeriesID == replacement.id && Calendar.current.isDate($0.taskOccurrence!, inSameDayAs: ahead.taskOccurrence!) })
    try expect(Workspace.decoded(next.encoded()).taskPlans?.count == 2)
}

@MainActor func calendarResolutionUpdatesBaselineAndRejectsStaleEdits() throws {
    var db = Workspace.demo(); let now = Date()
    var item = CalendarImportItem(key: "source", calendarTitle: "工作", externalID: "source", occurrence: nil, value: CalendarEventValue(title: "原题", body: "原文", start: now, end: now.addingTimeInterval(3600), allDay: false, timeZoneID: "UTC"), calendarID: "cal-1", eventID: "event-1")
    _ = try db.syncingCalendar([item], location: RecordingLocation(projectIDs: [db.projects[0].id]))
    let id = try require(db.records.first { $0.calendarLink?.key == item.key }?.id)
    var local = db.record(id)!; local.title = "本地标题"; local.body = "本地正文"; try db.putRecord(local)
    item.value.title = "日历标题"; item.value.body = "日历正文"
    let expected = db.record(id)!
    do { try db.resolveCalendar(item, expected: expected, choices: [.title: .local], reminders: nil); throw CheckFailure(description: "Partial conflict choice accepted") } catch is WorkspaceError {}
    try db.resolveCalendar(item, expected: expected, choices: [.title: .local, .body: .calendar], reminders: nil)
    try expect(db.record(id)?.title == "本地标题" && db.record(id)?.body == "日历正文")
    try expect(db.calendarChange(item, location: nil).state == .unchanged)
    do { try db.resolveCalendar(item, expected: expected, choices: [.title: .calendar, .body: .calendar], reminders: nil); throw CheckFailure(description: "Stale resolution accepted") } catch is WorkspaceError {}
    var moved = db.record(id)!; moved.reminderDates = [now.addingTimeInterval(-600)]; moved.startAt.addTimeInterval(60); try db.putRecord(moved)
    item.value.start.addTimeInterval(120)
    try db.resolveCalendar(item, expected: db.record(id)!, choices: [.start: .local], reminders: nil)
    try expect(db.calendarChange(item, location: nil).state == .unchanged)
}

@MainActor func calendarCancellationPreservesHistoryAndStopsReminders() throws {
    var db = Workspace.demo(); let now = Date()
    let item = CalendarImportItem(key: "cancel", calendarTitle: "工作", externalID: "cancel", occurrence: nil, value: CalendarEventValue(title: "未来会议", body: "保留纪要", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(10800), allDay: false, timeZoneID: "UTC"))
    _ = try db.syncingCalendar([item], location: RecordingLocation(projectIDs: [db.projects[0].id]))
    let id = try require(db.records.first { $0.calendarLink?.key == item.key }?.id)
    var value = db.record(id)!; value.reminderDates = [now.addingTimeInterval(3600)]; try db.putRecord(value)
    let original = db.record(id)!
    try db.handleCalendarSource(CalendarSourceReview(record: original, issue: .missing), decision: .cancelled)
    let cancelled = db.record(id)!
    try expect(cancelled.body == original.body && cancelled.reminderDates == original.reminderDates && cancelled.status == .paused)
    try expect(cancelled.reminderSchedule(in: DateInterval(start: now, duration: 86400)).isEmpty)
    try expect(db.calendarChange(item, location: nil).state == .conflict)
    try db.resolveCalendar(item, expected: cancelled, choices: [:], reminders: nil, resume: true)
    try expect(db.record(id)?.status == .active && db.record(id)?.calendarLink?.disposition == nil)
    try expect(db.record(id)!.reminderSchedule(in: DateInterval(start: now, duration: 86400)).count == 1)
    try db.handleCalendarSource(CalendarSourceReview(record: db.record(id)!, issue: .missing), decision: .cancelled)
    try db.handleCalendarSource(CalendarSourceReview(record: db.record(id)!, issue: .missing), decision: .keptHistory, restore: true)
    try expect(db.record(id)?.status == .active)
    var foreign = item; foreign.isCancelled = true; foreign.calendarID = "other-calendar"
    var identified = db.record(id)!; identified.calendarLink?.calendarID = "original-calendar"; try db.putRecord(identified)
    try expect(db.calendarChange(foreign, location: nil).state == .cancelled)
}
