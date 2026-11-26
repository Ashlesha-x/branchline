import Foundation
import ProgressCore

private func quickFixture() -> (Workspace, WorkRecord, WorkRecord) {
    var db = Workspace(); let project = Project(title: "快捷操作验证"); db.projects = [project]
    var dependency = WorkRecord(kind: .task, title: "前置任务"); dependency.projectIDs = [project.id]; dependency.startAt = Date(timeIntervalSince1970: 100)
    var task = dependency; task.id = UUID(); task.title = "目标任务"
    db.records = [dependency, task]; return (db, dependency, task)
}
func quickCompletionKeepsDependencyValidation() throws {
    var (db, dependency, task) = quickFixture(); task.dependencies = [dependency.id]; db.records[1] = task
    let previous = db; task.status = .completed
    try expectThrows { try db.putRecord(task) }; try expect(db == previous)
    dependency.status = .completed; try db.putRecord(dependency); try db.putRecord(task); try db.validate()
    try expect(db.record(task.id)?.completedAt != nil)
}
func quickUndoPreservesLaterWorkAndRejectsChangedTask() throws {
    var (db, other, before) = quickFixture(); var completed = before; completed.status = .completed
    try db.putRecord(completed); completed = try require(db.record(before.id))
    let undo = TaskCompletionUndo(before: before, completed: completed)
    other.title = "后续独立修改"; try db.putRecord(other)
    try db.undoTaskCompletion(undo); try db.validate()
    try expect(db.record(before.id)?.status == before.status && db.record(before.id)?.completedAt == before.completedAt)
    try expect(db.record(other.id)?.title == "后续独立修改")
    try db.putRecord(completed); var edited = completed; edited.body = "后续修改不能覆盖"; try db.putRecord(edited)
    let previous = db; try expectThrows { try db.undoTaskCompletion(undo) }; try expect(db == previous)
    db.records.removeAll { $0.id == before.id }; try expectThrows { try db.undoTaskCompletion(undo) }
}
func quickDeadlineChangesOnlyDeadlineFields() throws {
    let (_, _, original) = quickFixture(); var task = original
    task.timeZoneID = "Asia/Singapore"; task.taskScheduled = true
    task.startAt = ISO8601DateFormatter().date(from: "2026-10-27T01:00:00Z")!; task.endAt = task.startAt.addingTimeInterval(3600)
    task.reminderDates = [task.startAt]; task.relativeReminders = [.duePreviousDay9]
    let day = ISO8601DateFormatter().date(from: "2026-10-29T16:30:00Z")!
    var expected = task; expected.dueAt = ISO8601DateFormatter().date(from: "2026-10-29T16:00:00Z")!; expected.dueDateOnly = true
    let changed = try task.withDeadline(on: day); try expect(changed == expected)
    var meeting = task; meeting.kind = .meeting; try expectThrows { _ = try meeting.withDeadline(on: day) }
}
func quickDeadlineRetainsLocalTimeAcrossZones() throws {
    let (_, _, original) = quickFixture(); var task = original; task.timeZoneID = "America/New_York"; task.dueDateOnly = false
    task.dueAt = ISO8601DateFormatter().date(from: "2026-03-01T14:35:17Z")!
    let day = ISO8601DateFormatter().date(from: "2026-03-09T02:00:00Z")!
    let updated = try task.withDeadline(on: day)
    try expect(updated.dueAt == ISO8601DateFormatter().date(from: "2026-03-08T13:35:17Z")! && !updated.dueDateOnly)
    task.dueDateOnly = true
    try expect(try task.withDeadline(on: day).dueAt == ISO8601DateFormatter().date(from: "2026-03-08T05:00:00Z")!)
}
func quickDeadlineHandlesDSTGapOnChosenDay() throws {
    let (_, _, original) = quickFixture(); var task = original; task.timeZoneID = "America/New_York"; task.dueDateOnly = false
    task.dueAt = ISO8601DateFormatter().date(from: "2026-03-01T07:30:00Z")!
    let day = ISO8601DateFormatter().date(from: "2026-03-08T16:00:00Z")!
    try expect(try task.withDeadline(on: day).dueAt == ISO8601DateFormatter().date(from: "2026-03-08T07:00:00Z")!)
}
func browseHistoryRestoresContextAndOccurrence() throws {
    struct Location: Equatable { var object: String; var occurrence: Int; var category: String; var offset: Int }
    var history = BrowsingHistory<Location>()
    let source = Location(object: "成果", occurrence: 0, category: "搜索范围", offset: 320)
    let record = Location(object: "来源记录", occurrence: 0, category: "搜索范围", offset: 320)
    let branch = Location(object: "分支", occurrence: 0, category: "搜索范围", offset: 400)
    history.depart(from: source); history.depart(from: record)
    try expect(history.goBack(from: branch, allowing: { _ in true }) == record)
    try expect(history.goBack(from: record, allowing: { _ in true }) == source)
    try expect(history.goForward(from: source, allowing: { _ in true }) == record)
    let meeting = Location(object: "重复会议", occurrence: 28, category: "未来七天", offset: 210)
    history.depart(from: meeting)
    try expect(history.forward.isEmpty)
    try expect(history.goBack(from: branch, allowing: { _ in true }) == meeting)
}
func browseHistorySkipsMissingEntriesAndStaysBounded() throws {
    var history = BrowsingHistory<Int>()
    for value in 0..<100 { history.depart(from: value) }
    try expect(history.back.count == 80)
    try expect(history.goBack(from: 100, allowing: { $0 < 98 }) == 97)
    try expect(history.goForward(from: 97, allowing: { $0 != 100 }) == nil)
    history.reset(); try expect(history.back.isEmpty && history.forward.isEmpty)
}
