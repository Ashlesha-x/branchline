import Foundation
import ProgressCore

@MainActor func prepareNewFeatureFixture(at directory: String) throws {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let database = root.appendingPathComponent("personal.store")
    guard !FileManager.default.fileExists(atPath: database.path) else { throw WorkspaceError("Fixture store already exists; not overwritten") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lock = try WorkspaceProcessLock(directory: root)
    defer { withExtendedLifetime(lock) {} }
    var db = Workspace.demo()
    var repeated = WorkRecord(kind: .task, title: "每周资料归档")
    repeated.projectIDs = [db.projects[0].id]; repeated.dueAt = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!; repeated.taskRepeatRule = .weekly
    try db.createTaskPlan(from: repeated)
    var late = WorkRecord(title: "上月实验结果（本周补录）"); late.projectIDs = [db.projects[0].id]; late.startAt = Calendar.current.date(byAdding: .day, value: -40, to: Date())!; try db.putRecord(late)
    var current = WorkRecord(title: "本周方案梳理"); current.projectIDs = [db.projects[0].id]; current.body = "完成两版方案比较。\n下一步确认接口。"; try db.putRecord(current)
    var completed = WorkRecord(kind: .task, title: "已完成的资料整理"); completed.projectIDs = [db.projects[0].id]; completed.startAt = Date().addingTimeInterval(-86400); completed.status = .completed; completed.completedAt = Date(); try db.putRecord(completed)
    var pending = WorkRecord(title: "待迁移的会议草稿"); pending.branchID = db.branches[0].id; pending.body = "尚未保存的讨论内容。"; let draft = RecordDraft(record: pending, original: nil)
    if let source = ProcessInfo.processInfo.environment["BRANCHLINE_CALENDAR_FIXTURE"] {
        let migration = try MigrationBackup.decoded(Data(contentsOf: URL(fileURLWithPath: source)))
        if var linked = migration.workspace.records.first(where: { $0.calendarLink != nil }) {
            linked.projectIDs = [db.projects[0].id]; linked.branchID = nil; linked.title = "日历差异验收：本地标题"; linked.calendarLink?.lastImported.title = "日历差异验收：旧基准"
            try db.putRecord(linked)
            var missing = linked; missing.id = UUID(); missing.title = "来源缺失验收（模拟）"; missing.calendarLink?.key += "-missing"; missing.calendarLink?.externalID += "-missing"; missing.calendarLink?.eventID = nil; missing.reminderDates = [Date().addingTimeInterval(3600)]
            try db.putRecord(missing)
        }
    }
    try WorkspaceRepository(url: database).save(db)
    try RecordDraftRepository(url: root.appendingPathComponent("Drafts/records.json")).save([draft])
    try MigrationBackup(workspace: db, drafts: [draft]).encoded().write(to: root.appendingPathComponent("fixture-migration.json"), options: .atomic)
}
