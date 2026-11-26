import Foundation
import ProgressCore

@MainActor func migrationBackupPreservesDraftsAndReadsLegacy() throws {
    let workspace = Workspace.demo()
    var record = WorkRecord(title: "未保存的正文"); record.body = "正文\n保留空行\n\n继续"; record.branchID = workspace.branches[0].id
    let draft = RecordDraft(record: record, original: nil)
    let backup = MigrationBackup(workspace: workspace, drafts: [draft])
    let decoded = try MigrationBackup.decoded(backup.encoded())
    try expect(decoded.includesDrafts && decoded.drafts.count == 1)
    try expect(decoded.drafts[0].record.body == record.body && decoded.drafts[0].record.branchID == record.branchID)
    try expect(decoded.workspace.records.count == workspace.records.count)
    try expect(decoded.workspace.record(record.id) == nil)
    let old = try MigrationBackup.decoded(workspace.encoded())
    try expect(!old.includesDrafts && old.drafts.isEmpty)
    try expect(backup.encoded() == backup.encoded())
    var other = record; other.id = UUID(); other.title = "另一份"
    let second = RecordDraft(record: other, original: nil)
    try expect(MigrationBackup(workspace: workspace, drafts: [draft, second]).encoded() == MigrationBackup(workspace: workspace, drafts: [second, draft]).encoded())
}

@MainActor func migrationJournalRollsBackAndRecoversBothStores() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("branchline-migration-\(UUID())")
    let journal = MigrationRestoreJournal(url: root.appendingPathComponent("journal.json"))
    let original = MigrationBackup(workspace: .demo(), drafts: [])
    var next = original; next.workspace.projects[0].title = "新工作区"
    let draft = RecordDraft(record: WorkRecord(title: "仍然是草稿"), original: nil); next.drafts = [draft]
    var current = original
    try journal.apply(next, previous: original, saveWorkspace: { current.workspace = $0 }, saveDrafts: { current.drafts = $0 })
    try expect(current.workspace.projects[0].title == "新工作区" && current.drafts.count == 1)
    do {
        try journal.apply(original, previous: next, saveWorkspace: { _ in throw WorkspaceError("写入失败") }, saveDrafts: { current.drafts = $0 })
        throw CheckFailure(description: "Expected interrupted restore")
    } catch let error as MigrationRestoreFailure { try expect(error.recoveryRequired) }
    try journal.recover(saveWorkspace: { current.workspace = $0 }, saveDrafts: { current.drafts = $0 })
    try expect(MigrationBackup(workspace: current.workspace, drafts: current.drafts).encoded() == next.encoded())
    var failed = false
    do {
        try journal.apply(original, previous: next, saveWorkspace: { value in
            if !failed { failed = true; throw WorkspaceError("一次失败") }; current.workspace = value
        }, saveDrafts: { current.drafts = $0 })
        throw CheckFailure(description: "Expected rollback")
    } catch let error as MigrationRestoreFailure { try expect(!error.recoveryRequired) }
    try expect(MigrationBackup(workspace: current.workspace, drafts: current.drafts).encoded() == next.encoded())
}

@MainActor func reviewsSeparateOccurrenceCompletionAndLateEntry() throws {
    let f = ISO8601DateFormatter()
    func day(_ text: String) -> Date { f.date(from: text + "T12:00:00Z")! }
    var db = Workspace()
    var project = Project(title: "项目"); project.createdAt = day("2026-09-01"); db.projects = [project]
    var late = WorkRecord(title: "补记上个月"); late.projectIDs = [project.id]; late.startAt = day("2026-10-01"); late.createdAt = day("2026-11-02")
    var progress = late; progress.id = UUID(); progress.title = "本期发生"; progress.startAt = day("2026-11-02")
    var done = WorkRecord(kind: .task, title: "本期完成"); done.projectIDs = [project.id]; done.startAt = day("2026-10-01"); done.taskScheduled = true; done.createdAt = day("2026-10-01"); done.status = .completed; done.completedAt = day("2026-11-02")
    var old = done; old.id = UUID(); old.title = "旧成果本期录入"; old.completedAt = day("2026-10-02"); old.createdAt = day("2026-11-02"); old.taskScheduled = false; old.startAt = old.createdAt
    db.records = [late, progress, done, old]; try db.validate()
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let review = try db.review(from: day("2026-11-01"), through: day("2026-11-03"), projectID: project.id, branchID: nil, now: day("2026-11-03"), calendar: calendar)
    try expect(review.sections[0].entries.map(\.entityID) == [progress.id])
    try expect(review.sections[1].entries.map(\.entityID) == [done.id])
    try expect(review.sections.first(where: { $0.title.contains("历史补记") })?.entries.map(\.entityID) == [late.id])
    try expect(!review.markdown.contains("branchline://"))
    try expect(review.sourceAppendix.contains("branchline://record/" + done.id.uuidString))
}

@MainActor func compoundFiltersRespectDateMeaningAndTaskState() throws {
    var db = Workspace.demo()
    var task = WorkRecord(kind: .task, title: "暂停任务"); task.projectIDs = [db.projects[0].id]; task.status = .paused
    task.createdAt = Date(); task.startAt = Date(); task.dueAt = Date().addingTimeInterval(86400); db.records.append(task)
    var filter = RecordFilter(); filter.projectID = db.projects[0].id; filter.taskStatus = .paused
    try expect(filter.matches(task, in: db))
    filter.dateField = .completion; try expect(!filter.matches(task, in: db))
    filter.dateField = .occurrence; filter.from = Date().addingTimeInterval(-86400); filter.through = Date().addingTimeInterval(86400)
    try expect(!filter.matches(task, in: db))
    filter.dateField = .deadline; try expect(filter.matches(task, in: db))
    filter.dateField = .entered; try expect(filter.matches(task, in: db))
    filter.branchID = db.branches[0].id; try expect(!filter.matches(task, in: db))
    try expect(db.search("", includeAll: true).contains { $0.id == task.id })
    try expect(db.search("").isEmpty)
}
