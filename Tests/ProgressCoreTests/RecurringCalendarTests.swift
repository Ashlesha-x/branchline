import Foundation
import ProgressCore

@MainActor func recurringTasksHaveIndependentStatesAndStableMaterialization() throws {
    var db = Workspace.demo()
    let now = Date()
    var task = WorkRecord(kind: .task, title: "每周整理数据"); task.projectIDs = [db.projects[0].id]; task.startAt = now.addingTimeInterval(-1); task.dueAt = now; task.taskRepeatRule = .weekly
    try db.createTaskPlan(from: task, now: now)
    let id = try require(db.taskPlans?.first?.id)
    let instances = db.records.filter { $0.taskSeriesID == id }
    try expect(instances.count >= 4 && instances.count <= 6)
    try expect(Set(instances.map(\.id)).count == instances.count)
    try expect(db.record(task.id) != nil)
    let count = db.records.count
    try expect(!db.materializeTaskPlans(now: now))
    try expect(db.records.count == count)
    var first = try require(db.record(task.id)); first.status = .completed; first.completedAt = now
    try db.putRecord(first, now: now)
    try expect(db.records.filter { $0.taskSeriesID == id && $0.status == .completed }.count == 1)
    let reopened = try Workspace.decoded(db.encoded())
    try expect(reopened.taskPlans?.count == 1 && reopened.records.count == count)
    try expect(db.materializeTaskPlans(now: now.addingTimeInterval(86400 * 15)))
    try expect(db.records.count > count)
    try db.stopTaskPlan(id, now: now)
    try expect(db.taskPlans?.first?.active == false)
    try expect(db.records.filter { $0.taskSeriesID == id && ($0.taskOccurrence ?? now) > now }.allSatisfy { $0.status == .archived })
    try db.validate()
}

@MainActor func recurringTaskDeletionAndTrashRetainPlans() throws {
    var db = Workspace.demo()
    var task = WorkRecord(kind: .task, title: "每天检查设备"); task.branchID = db.branches[0].id; task.dueAt = Date(); task.taskRepeatRule = .daily
    try db.createTaskPlan(from: task)
    let plan = try require(db.taskPlans?.first)
    let item = try require(db.records.first { $0.taskSeriesID == plan.id })
    let deleted = try db.movingToTrash(.record(item.id))
    try expect(deleted.taskPlans?.first?.excluded.contains(item.taskOccurrence!) == true)
    let restored = try deleted.restoringTrash(deleted.trash.last!.id)
    try expect(restored.record(item.id) != nil && restored.taskPlans?.first?.excluded.isEmpty == true)
    let removedBranch = try db.movingToTrash(.branch(task.branchID!))
    try expect(removedBranch.taskPlans?.isEmpty == true)
    let back = try removedBranch.restoringTrash(removedBranch.trash.last!.id)
    try expect(back.taskPlans?.first?.id == plan.id)
    try back.validate()
}

@MainActor func calendarSyncDeduplicatesAndPreservesLocalEdits() throws {
    var db = Workspace.demo()
    let location = RecordingLocation(projectIDs: [db.projects[0].id])
    let start = Date(); var value = CalendarEventValue(title: "日历会议", body: "原始纪要", start: start, end: start.addingTimeInterval(3600), allDay: false, timeZoneID: "Asia/Singapore")
    var source = CalendarImportItem(key: "server-uid", calendarTitle: "工作", externalID: "server-uid", occurrence: nil, value: value)
    let first = try db.syncingCalendar([source], location: location)
    try expect(first.inserted == 1)
    let id = try require(db.records.first { $0.calendarLink?.key == source.key }?.id)
    let again = try db.syncingCalendar([source], location: location)
    try expect(again.inserted == 0 && again.updated == 0)
    var local = try require(db.record(id)); local.body = "App 内补充"; try db.putRecord(local)
    value.start.addTimeInterval(86400); value.end.addTimeInterval(86400); source.value = value
    let rescheduled = try db.syncingCalendar([source], location: nil)
    try expect(rescheduled.updated == 1 && db.record(id)?.body == "App 内补充")
    try expect(db.record(id)?.startAt == value.start)
    source.value.body = "日历也修改了正文"
    let conflict = try db.syncingCalendar([source], location: nil)
    try expect(conflict.conflicts == 1 && db.record(id)?.body == "App 内补充")
    let reopened = try Workspace.decoded(db.encoded())
    try expect(reopened.record(id)?.calendarLink?.key == source.key)
    try expect(reopened.calendarChange(source, location: nil).state == .conflict)
}

@MainActor func calendarSyncKeepsOccurrenceIdentityAndProtectsFixedReminders() throws {
    var db = Workspace.demo()
    let location = RecordingLocation(projectIDs: [db.projects[0].id])
    let start = Date()
    let value = CalendarEventValue(title: "重复系列的一次", body: "", start: start, end: start.addingTimeInterval(3600), allDay: false, timeZoneID: "UTC")
    var first = CalendarImportItem(key: "series|one", calendarTitle: "日历", externalID: "series", occurrence: start, value: value)
    var second = first; second.key = "series|two"; second.occurrence = start.addingTimeInterval(86400); second.value.start.addTimeInterval(86400); second.value.end.addTimeInterval(86400)
    let result = try db.syncingCalendar([first, second], location: location)
    try expect(result.inserted == 2)
    let index = db.records.firstIndex { $0.calendarLink?.key == first.key }!
    db.records[index].reminderDates = [start.addingTimeInterval(-900)]
    first.value.start.addTimeInterval(7200); first.value.end.addTimeInterval(7200)
    try expect(db.calendarChange(first, location: nil).state == .conflict)
    try expect(db.records.filter { $0.calendarLink != nil }.count == 2)
}
