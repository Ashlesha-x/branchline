import Foundation
import ProgressCore

private func moment(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func recurringFixture() -> (Workspace, WorkRecord) {
    var db = Workspace(); let project = Project(title: "会议项目"); db.projects = [project]
    var meeting = WorkRecord(kind: .meeting, title: "每月会议"); meeting.projectIDs = [project.id]
    meeting.timeZoneID = "Asia/Singapore"; meeting.startAt = moment("2026-01-31T01:00:00Z"); meeting.endAt = meeting.startAt.addingTimeInterval(3600)
    meeting.repeatRule = .monthly; meeting.relativeReminders = [.start15Minutes]; meeting.reminderDates = [meeting.startAt.addingTimeInterval(-3600)]
    db.records = [meeting]; return (db, meeting)
}
func trashRestoresSingleDeletionAndPreservesLaterEdits() throws {
    var db = Workspace.demo()
    let task = try require(db.records.first { $0.kind == .task })
    var dependent = WorkRecord(kind: .task, title: "依赖项"); dependent.projectIDs = [db.projects[0].id]; dependent.dependencies = [task.id]
    db.records.append(dependent)
    var next = try db.movingToTrash(.record(task.id))
    let entry = try require(next.trash.last)
    let index = next.records.firstIndex { $0.id == dependent.id }!
    next.records[index].body = "删除之后写的文字"
    let extra = Project(title: "后来创建的项目"); next.projects.append(extra)
    next = try next.restoringTrash(entry.id)
    try expect(next.record(task.id) == task)
    try expect(next.record(dependent.id)?.body == "删除之后写的文字")
    try expect(next.record(dependent.id)?.dependencies == [task.id])
    try expect(next.project(extra.id) == extra && next.trash.isEmpty)
    try expectThrows { _ = try next.restoringTrash(entry.id) }
}
func trashSharedProjectAndConflictSafety() throws {
    var db = Workspace.demo()
    let shared = try require(db.branches.first { $0.projectIDs.count > 1 })
    let project = try require(db.project(shared.projectIDs[0]))
    var next = try db.movingToTrash(.project(project.id))
    let entry = next.trash.last!
    next.branches[next.branches.firstIndex { $0.id == shared.id }!].note = "后来改的说明"
    let restored = try next.restoringTrash(entry.id)
    try expect(restored.branch(shared.id)?.projectIDs == shared.projectIDs)
    try expect(restored.branch(shared.id)?.note == "后来改的说明")
    // A changed relationship must not be overwritten by recovery.
    let other = Project(title: "新关联"); next.projects.append(other)
    next.branches[next.branches.firstIndex { $0.id == shared.id }!].projectIDs.append(other.id)
    let saved = next
    try expectThrows { _ = try next.restoringTrash(entry.id) }
    try expect(next == saved)
    db = try db.movingToTrash(.record(db.records[0].id))
    db.records.append(db.records[0]) // deliberately invalid duplicate must still be rejected
    try expectThrows { try db.validate() }
}
@MainActor func trashPersistenceAndLegacyMigration() throws {
    let (db, meeting) = recurringFixture()
    let trashed = try db.movingToTrash(.record(meeting.id))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineBatchTwo-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("workspace.store")
    try WorkspaceRepository(url: url).save(trashed)
    let reopened = try require(WorkspaceRepository(url: url).load())
    try expect(reopened.trash.map(\.changes) == trashed.trash.map(\.changes) && reopened.records.isEmpty)
    try expect(try reopened.restoringTrash(reopened.trash[0].id).record(meeting.id) == meeting)
    var json = try JSONSerialization.jsonObject(with: db.encoded()) as! [String: Any]
    json["version"] = 1; json.removeValue(forKey: "trashEntries")
    let old = try Workspace.decoded(JSONSerialization.data(withJSONObject: json))
    try expect(old.version == 4 && old.trash.isEmpty)
    var corrupt = trashed; corrupt.trashEntries![0].changes[0].before = Data("bad".utf8)
    do { try corrupt.validate(); throw CheckFailure(description: "Invalid trash accepted") } catch is DecodingError { }
}
func recurringSingleEditAndReminders() throws {
    let (db, meeting) = recurringFixture(); let selected = moment("2026-02-28T01:00:00Z")
    var draft = meeting.occurrenceDraft(at: selected); draft.title = "仅本次改名"; draft.startAt = selected.addingTimeInterval(7200); draft.endAt = draft.startAt.addingTimeInterval(3600); draft.reminderDates = []
    let next = try db.editingRecurring(meeting.id, occurrence: selected, input: draft, scope: .occurrence)
    let child = try require(next.records.first { $0.seriesID == meeting.id })
    try expect(child.title == draft.title && child.repeatRule == .none && child.originalOccurrence == selected)
    let interval = DateInterval(start: moment("2026-02-01T00:00:00Z"), end: moment("2026-04-01T00:00:00Z"))
    try expect(CalendarLogic.occurrences(of: next.record(meeting.id)!, in: interval) == [moment("2026-03-31T01:00:00Z")])
    try expect(!next.record(meeting.id)!.reminderOccurrences(in: interval).contains(selected.addingTimeInterval(-900)))
    try expect(!next.record(meeting.id)!.reminderOccurrences(in: interval).contains(selected.addingTimeInterval(-3600)))
    try expect(child.reminderOccurrences(in: interval) == [draft.startAt.addingTimeInterval(-900)])
    let roundTrip = try Workspace.decoded(next.encoded())
    try expect(roundTrip.record(child.id)?.originalOccurrence == selected && roundTrip.record(meeting.id)?.excludedOccurrences == [selected])
}
func recurringFollowingPreservesMonthEndAndExceptions() throws {
    let (db, meeting) = recurringFixture(); let boundary = moment("2026-02-28T01:00:00Z"), march = moment("2026-03-31T01:00:00Z")
    var exception = meeting.occurrenceDraft(at: march); exception.title = "三月例外"; exception.startAt = march.addingTimeInterval(86400); exception.endAt = exception.startAt.addingTimeInterval(3600)
    let withException = try db.editingRecurring(meeting.id, occurrence: march, input: exception, scope: .occurrence)
    var draft = withException.record(meeting.id)!.occurrenceDraft(at: boundary); draft.title = "新系列"
    let next = try withException.editingRecurring(meeting.id, occurrence: boundary, input: draft, scope: .following)
    let newSeries = try require(next.records.first { $0.title == "新系列" })
    let interval = DateInterval(start: moment("2026-01-01T00:00:00Z"), end: moment("2026-05-01T00:00:00Z"))
    try expect(CalendarLogic.occurrences(of: next.record(meeting.id)!, in: interval) == [meeting.startAt])
    try expect(CalendarLogic.occurrences(of: newSeries, in: interval) == [boundary, moment("2026-04-30T01:00:00Z")])
    try expect(next.records.first { $0.title == "三月例外" }?.seriesID == newSeries.id)
    try expect(newSeries.reminderOccurrences(in: interval).contains(boundary.addingTimeInterval(-3600)))
    try expect(!newSeries.reminderOccurrences(in: interval).contains(march.addingTimeInterval(-3600)))
}
func recurringDeletionScopesAndRecovery() throws {
    let (db, meeting) = recurringFixture(); let boundary = moment("2026-02-28T01:00:00Z"), march = moment("2026-03-31T01:00:00Z")
    let single = try db.deletingRecurring(meeting.id, occurrence: boundary, scope: .occurrence).retainingDeletion(from: db, title: "取消本次")
    let restored = try single.restoringTrash(single.trash.last!.id)
    try expect(restored.record(meeting.id)?.excludedOccurrences?.isEmpty != false)
    var draft = meeting.occurrenceDraft(at: march); draft.title = "未来例外"
    let withException = try db.editingRecurring(meeting.id, occurrence: march, input: draft, scope: .occurrence)
    let next = try withException.deletingRecurring(meeting.id, occurrence: boundary, scope: .following).retainingDeletion(from: withException, title: "取消以后")
    try expect(next.records.count == 1 && next.records[0].repeatUntil == boundary)
    let again = try next.restoringTrash(next.trash.last!.id)
    try expect(again.records.count == 2 && again.record(meeting.id)?.repeatUntil == nil)
    try expect(try again.deletingRecurring(meeting.id, occurrence: meeting.startAt, scope: .series).records.isEmpty)
}
func recurringWholeEditRemapsExceptionsAcrossDST() throws {
    var (db, meeting) = recurringFixture()
    meeting.repeatRule = .weekly; meeting.timeZoneID = "America/New_York"; meeting.startAt = moment("2026-03-01T14:00:00Z"); meeting.endAt = meeting.startAt.addingTimeInterval(3600); meeting.reminderDates = []
    db.records = [meeting]
    let excluded = moment("2026-03-08T13:00:00Z")
    let canceled = try db.deletingRecurring(meeting.id, occurrence: excluded, scope: .occurrence)
    var draft = canceled.record(meeting.id)!; draft.startAt = draft.startAt.addingTimeInterval(3600); draft.endAt = draft.endAt?.addingTimeInterval(3600)
    let next = try canceled.editingRecurring(meeting.id, occurrence: meeting.startAt, input: draft, scope: .series)
    try expect(next.record(meeting.id)?.excludedOccurrences == [moment("2026-03-08T14:00:00Z")])
    let dates = CalendarLogic.occurrences(of: next.record(meeting.id)!, in: DateInterval(start: moment("2026-03-01T00:00:00Z"), end: moment("2026-03-16T00:00:00Z")))
    try expect(dates == [moment("2026-03-01T15:00:00Z"), moment("2026-03-15T14:00:00Z")])
}

func trashMultipleDeletionsRestoreInDependencyOrder() throws {
    let (db, meeting) = recurringFixture()
    let first = try db.movingToTrash(.record(meeting.id))
    let second = try first.movingToTrash(.project(db.projects[0].id))
    try expectThrows { _ = try second.restoringTrash(first.trash[0].id) }
    let parentRestored = try second.restoringTrash(second.trash.last!.id)
    let restored = try parentRestored.restoringTrash(first.trash[0].id)
    try expect(restored.record(meeting.id) == meeting && restored.trash.isEmpty)
    var collision = first; collision.records.append(meeting)
    try expectThrows { _ = try collision.restoringTrash(first.trash[0].id) }
}
func recurringMovedExceptionsAndStoppingSeries() throws {
    var (db, meeting) = recurringFixture()
    let other = Project(title: "另一个项目"); db.projects.append(other)
    let date = moment("2026-03-31T01:00:00Z")
    var child = meeting.occurrenceDraft(at: date); child.projectIDs = [other.id]; child.title = "跨项目例外"
    var next = try db.editingRecurring(meeting.id, occurrence: date, input: child, scope: .occurrence)
    let childID = next.records.first { $0.seriesID == meeting.id }!.id
    let removed = try next.movingToTrash(.project(meeting.projectIDs[0]))
    try expect(removed.records.isEmpty)
    try expect(try removed.restoringTrash(removed.trash.last!.id).record(childID)?.projectIDs == [other.id])
    // An imported ordering may place the exception before its parent.
    next.records.reverse()
    let canceled = try next.deletingRecurring(meeting.id, occurrence: moment("2026-02-28T01:00:00Z"), scope: .following)
    try expect(canceled.record(meeting.id)?.repeatUntil == moment("2026-02-28T01:00:00Z") && canceled.record(childID) == nil)
    meeting = next.record(meeting.id)!; meeting.repeatRule = .none
    let stopped = try next.editingRecurring(meeting.id, occurrence: meeting.startAt, input: meeting, scope: .series)
    try expect(stopped.record(childID)?.seriesID == nil && stopped.record(childID)?.title == "跨项目例外")
    try stopped.validate()
}
