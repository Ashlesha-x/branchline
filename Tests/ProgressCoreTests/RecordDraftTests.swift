import Foundation
import ProgressCore

@MainActor func recordDraftsSurviveReopenAndClearWithoutRemovingFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("branchline-draft-\(UUID())/records.json")
    let repository = RecordDraftRepository(url: url)
    let workspace = Workspace.demo()
    var record = WorkRecord(kind: .meeting, title: "未完成的会议纪要")
    record.branchID = workspace.branches[0].id; record.body = "长正文\n待补充内容"; record.endAt = record.startAt.addingTimeInterval(3600)
    let draft = RecordDraft(record: record, original: nil)
    try repository.save([draft])
    let reopened = try RecordDraftRepository(url: url).load()
    try expect(reopened == [draft])
    try expect(reopened[0].record.recordingLocation == record.recordingLocation)
    try repository.save([])
    try expect(FileManager.default.fileExists(atPath: url.path))
    try expect(repository.load().isEmpty)
    let broken = Data("incomplete write".utf8); try broken.write(to: url)
    do { _ = try repository.load(); throw CheckFailure(description: "Corrupt draft accepted") }
    catch is CheckFailure { throw CheckFailure(description: "Corrupt draft accepted") } catch {}
    try expect(Data(contentsOf: url) == broken)
}

@MainActor func draftConflictAndCommitChecksRespectWorkspaceDatePrecision() throws {
    var workspace = Workspace.demo()
    var original = workspace.records[0]; original.startAt.addTimeInterval(0.123); original.updatedAt.addTimeInterval(0.456)
    workspace.records[0] = original
    var edited = original; edited.body += "未保存的补充"
    let draft = RecordDraft(record: edited, original: original)
    var reopened = try Workspace.decoded(workspace.encoded())
    try expect(!draft.conflicts(in: reopened))
    reopened.records[0].body = "在其他入口更新了正文"
    try expect(draft.conflicts(in: reopened))
    reopened.records.removeFirst()
    try expect(draft.conflicts(in: reopened))
    var committed = edited; committed.updatedAt = Date()
    workspace.records[0] = committed
    reopened = try Workspace.decoded(workspace.encoded())
    try expect(draft.alreadySaved(in: reopened))
    var newRecord = WorkRecord(title: "崩溃前已正式保存")
    let unsaved = RecordDraft(record: newRecord, original: nil)
    newRecord.projectIDs = [workspace.projects[0].id]
    let snapshot = RecordDraft(record: newRecord, original: nil)
    try workspace.putRecord(newRecord)
    try expect(snapshot.alreadySaved(in: Workspace.decoded(workspace.encoded())))
    try expect(unsaved.conflicts(in: workspace))
}

@MainActor func recurringDraftScopesRemainIndependent() throws {
    let record = WorkRecord(kind: .meeting, title: "重复会议草稿")
    let date = Date(timeIntervalSince1970: 1_800_000_000.25)
    let single = RecordDraft(record: record, original: record, recurrence: DraftRecurrence(seriesID: record.id, occurrence: date, scope: .occurrence))
    let following = RecordDraft(record: record, original: record, recurrence: DraftRecurrence(seriesID: record.id, occurrence: date, scope: .following))
    try expect(single.id != following.id)
    try expect(single.id != RecordDraft.key(record.id))
    let rounded = DraftRecurrence(seriesID: record.id, occurrence: Date(timeIntervalSince1970: 1_800_000_000), scope: .occurrence)
    try expect(single.id == RecordDraft.key(record.id, recurrence: rounded))
    var workspace = Workspace.demo()
    var series = record; series.projectIDs = [workspace.projects[0].id]; series.repeatRule = .daily
    series.startAt = date; series.endAt = date.addingTimeInterval(3600)
    try workspace.putRecord(series)
    let stored = try require(workspace.record(series.id))
    let occurrence = try require(CalendarLogic.occurrences(of: stored, in: DateInterval(start: date.addingTimeInterval(-1), duration: 3)).first)
    var input = stored.occurrenceDraft(at: occurrence); input.body = "恢复单次会议编辑"
    let recovery = RecordDraft(record: input, original: stored, recurrence: DraftRecurrence(seriesID: stored.id, occurrence: occurrence, scope: .occurrence))
    let reopened = try Workspace.decoded(workspace.encoded())
    try expect(!recovery.conflicts(in: reopened))
    let target = try require(recovery.recurrenceForRecovery(in: reopened))
    let saved = try reopened.editingRecurring(stored.id, occurrence: target.occurrence, input: input, scope: .occurrence)
    try expect(saved.records.contains { $0.body == input.body && $0.seriesID == stored.id })
}
