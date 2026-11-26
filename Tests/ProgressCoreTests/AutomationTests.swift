import Foundation
import ProgressCore

private func operation(_ action: String, _ entity: String, _ key: String, _ fields: [String: JSONValue]) -> JSONValue {
    .object(["action": .string(action), "entity": .string(entity), action == "create" ? "ref" : "id": .string(key), "fields": .object(fields)])
}
private func batch(_ w: Workspace, _ ops: [JSONValue], requestID: String = UUID().uuidString) -> JSONValue {
    .object(["requestID": .string(requestID), "expectedRevision": .string(w.automationRevision), "operations": .array(ops)])
}
private func createdWorkspace() throws -> (Workspace, JSONValue) {
    let w = Workspace()
    let request = batch(w, [operation("create", "project", "p", ["title": .string("接口测试")]), operation("create", "branch", "b", ["title": .string("设计"), "projectIDs": .array([.string("$p")]), "originProjectID": .string("$p")]), operation("create", "record", "r", ["kind": .string("task"), "title": .string("检查布局"), "branchID": .string("$b")])])
    return (try AutomationAPI.plan(request, in: w).workspace, request)
}
func automationAtomicReferencesAndReplay() throws {
    let (w, request) = try createdWorkspace()
    try expect(w.projects.count == 1 && w.branches.count == 1 && w.records.count == 1)
    try expect(w.records[0].branchID == w.branches[0].id && w.branches[0].projectIDs == [w.projects[0].id])
    let replay = try AutomationAPI.plan(request, in: w)
    try expect(replay.replay && replay.workspace == w)
    let restored = try Workspace.decoded(w.encoded())
    try expect(try AutomationAPI.plan(request, in: restored).replay)
    var changed = request.object!; changed["operations"] = .array([operation("create", "project", "p", ["title": .string("不同内容")])])
    try expectThrows { _ = try AutomationAPI.plan(.object(changed), in: w) }
}
func automationConflictsAndRollback() throws {
    let (w, _) = try createdWorkspace()
    let r = batch(w, [operation("update", "record", w.records[0].id.uuidString, ["title": .string("新标题")])])
    var edited = w; edited.records[0].body = "人工编辑"
    try expectThrows { _ = try AutomationAPI.plan(r, in: edited) }
    let bad = batch(w, [operation("create", "project", "new", ["title": .string("不应保存")]), operation("create", "record", "bad", ["kind": .string("task"), "title": .string("无效归属"), "branchID": .string(UUID().uuidString)])])
    try expectThrows { _ = try AutomationAPI.plan(bad, in: w) }
    try expect(w.projects.count == 1 && w.automationReceipts?.count == 1)
}
func automationPatchAndValidation() throws {
    let (w, _) = try createdWorkspace()
    let r = batch(w, [operation("update", "record", w.records[0].id.uuidString, ["title": .string("新标题"), "dueAt": .string("2026-12-01T09:00:00Z")])])
    let next = try AutomationAPI.plan(r, in: w).workspace
    try expect(next.records[0].title == "新标题" && next.records[0].branchID == w.records[0].branchID)
    let cleared = try AutomationAPI.plan(batch(next, [operation("update", "record", next.records[0].id.uuidString, ["dueAt": .null])]), in: next).workspace
    try expect(cleared.records[0].dueAt == nil)
    try expectThrows { _ = try AutomationAPI.plan(batch(w, [operation("update", "record", w.records[0].id.uuidString, ["id": .string(UUID().uuidString)])]), in: w) }
    try expectThrows { _ = try AutomationAPI.plan(batch(w, [operation("update", "record", w.records[0].id.uuidString, ["dependencies": .array([.string(w.records[0].id.uuidString)])])]), in: w) }
}
func automationDependenciesAndReminders() throws {
    var (w, _) = try createdWorkspace()
    let forward = batch(w, [
        operation("create", "record", "dependent", ["kind": .string("task"), "title": .string("不能提前完成"), "branchID": .string(w.branches[0].id.uuidString), "status": .string("completed"), "dependencies": .array([.string("$later")])]),
        operation("create", "record", "later", ["kind": .string("task"), "title": .string("尚未完成的前置任务"), "branchID": .string(w.branches[0].id.uuidString)])
    ])
    try expectThrows { _ = try AutomationAPI.plan(forward, in: w) }
    var task = WorkRecord(kind: .task, title: "后续任务"); task.branchID = w.branches[0].id; task.dependencies = [w.records[0].id]; w.records.append(task)
    try expectThrows { _ = try AutomationAPI.plan(batch(w, [operation("update", "record", task.id.uuidString, ["status": .string("completed")])]), in: w) }
    let done = try AutomationAPI.plan(batch(w, [operation("update", "record", w.records[0].id.uuidString, ["status": .string("completed")]), operation("update", "record", task.id.uuidString, ["status": .string("completed")])]), in: w).workspace
    try expect(done.records.allSatisfy { $0.status == .completed })
    w.records[0].reminderDates = [Date().addingTimeInterval(3600)]
    let update = operation("update", "record", w.records[0].id.uuidString, ["dueAt": .string("2026-12-01T09:00:00Z")])
    try expectThrows { _ = try AutomationAPI.plan(batch(w, [update]), in: w) }
    var explicit = update.object!; explicit["fixedReminderPolicy"] = .string("keep")
    try expect(try AutomationAPI.plan(batch(w, [.object(explicit)]), in: w).workspace.records[0].reminderDates == w.records[0].reminderDates)
}
func automationScopedReadsAndPagination() throws {
    let (w, _) = try createdWorkspace()
    let context = try AutomationAPI.query("get_project_context", arguments: .object(["projectID": .string(w.projects[0].id.uuidString), "limit": .number(1)]), workspace: w)
    try expect(context["items"].array?.count == 1 && context["revision"].string == w.automationRevision)
    let hits = try AutomationAPI.query("search", arguments: .object(["query": .string("布局")]), workspace: w)
    try expect(hits["items"].array?.count == 1)
    try expectThrows { _ = try AutomationAPI.query("search", arguments: .object(["query": .string("布局"), "projectID": .string("bad")]), workspace: w) }
    let bounded = try AutomationAPI.query("list_projects", arguments: .object(["offset": .number(1e100)]), workspace: w)
    try expect(bounded["items"].array?.isEmpty == true)
}
@MainActor func automationPersistenceAndSingleWriter() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("branchline-api-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lock = try WorkspaceProcessLock(directory: dir)
    try withExtendedLifetime(lock) { try expectThrows { _ = try WorkspaceProcessLock(directory: dir) } }
    let (w, request) = try createdWorkspace()
    let repo = try WorkspaceRepository(url: dir.appendingPathComponent("personal.store")); try repo.save(w)
    let reopened = try WorkspaceRepository(url: dir.appendingPathComponent("personal.store"))
    let stored = try require(reopened.load())
    try expect(try AutomationAPI.plan(request, in: stored).replay)
    let legacy = Workspace(); try expect(try Workspace.decoded(legacy.encoded()).automationReceipts == nil)
}
func automationMergeAndRecurrenceBoundaries() throws {
    let (w, _) = try createdWorkspace()
    let merged = try AutomationAPI.plan(batch(w, [operation("create", "merge", "m", ["branchID": .string(w.branches[0].id.uuidString), "projectID": .string(w.projects[0].id.uuidString), "summary": .string("阶段完成"), "sourceRecordIDs": .array([.string(w.records[0].id.uuidString)])])]), in: w).workspace
    try expect(merged.merges.count == 1)
    var recurring = w
    var r = WorkRecord(kind: .meeting, title: "每周会议"); r.branchID = w.branches[0].id; r.endAt = r.startAt.addingTimeInterval(3600); r.repeatRule = .weekly; recurring.records.append(r)
    try expectThrows { _ = try AutomationAPI.plan(batch(recurring, [operation("update", "record", r.id.uuidString, ["title": .string("不能绕过范围选择")])]), in: recurring) }
}
