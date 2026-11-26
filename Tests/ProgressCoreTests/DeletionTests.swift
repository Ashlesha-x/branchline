import Foundation
import ProgressCore

func deletingProjectPreservesSharedWork() throws {
    var db = Workspace.demo()
    let shared = try require(db.branches.first { $0.projectIDs.count == 2 })
    let deleted = shared.projectIDs[0], surviving = shared.projectIDs[1]
    let exclusive = db.branches.filter { $0.projectIDs == [deleted] }
    var record = WorkRecord(title: "共享主干记录"); record.projectIDs = [deleted, surviving]; db.records.append(record)
    let original = try db.encoded()
    let next = try db.deleting(.project(deleted))
    try expect(next.project(deleted) == nil)
    try expect(exclusive.allSatisfy { next.branch($0.id) == nil })
    try expect(next.branch(shared.id)?.projectIDs == [surviving])
    try expect(next.branch(shared.id)?.originProjectID != deleted)
    try expect(next.records.filter { $0.branchID == shared.id }.map(\.id) == db.records.filter { $0.branchID == shared.id }.map(\.id))
    try expect(next.record(record.id)?.projectIDs == [surviving])
    try expect(!next.merges.contains { $0.projectID == deleted })
    try expect(next.merges.filter { $0.projectID == surviving } == db.merges.filter { $0.projectID == surviving })
    try expect(try db.encoded() == original)
    try expect(try Workspace.decoded(next.encoded()).encoded() == next.encoded())
    try expect(try db.deletionPreview(.project(deleted)).detail.contains("共享分支保留 1 条"))
}

func deletingBranchClearsDependenciesAndMerges() throws {
    var db = Workspace.demo()
    let branch = try require(db.branches.first { $0.projectIDs.count == 2 })
    var dependency = WorkRecord(kind: .task, title: "共享分支任务"); dependency.branchID = branch.id; db.records.append(dependency)
    var dependent = WorkRecord(kind: .task, title: "等待共享任务"); dependent.projectIDs = [branch.projectIDs[0]]; dependent.dependencies = [dependency.id]; db.records.append(dependent)
    db.history.append(ChangeRecord(entityID: dependency.id, summary: "任务状态"))
    let next = try db.deleting(.branch(branch.id))
    try expect(next.projects == db.projects)
    try expect(!next.records.contains { $0.branchID == branch.id })
    try expect(!next.merges.contains { $0.branchID == branch.id })
    try expect(next.record(dependent.id)?.dependencies.isEmpty == true)
    try expect(next.record(dependent.id)?.status == .active)
    try expect(!next.history.contains { $0.entityID == dependency.id })
    try expect(try db.deletionPreview(.branch(branch.id)).detail.contains("1 项任务"))
    try next.validate()
}

func deletingRecordPreservesMergeSnapshotAndSeriesSafety() throws {
    let db = Workspace.demo()
    let merge = try require(db.merges.first { !$0.sourceRecordIDs.isEmpty })
    let id = merge.sourceRecordIDs[0]
    let next = try db.deleting(.record(id))
    let updated = try require(next.merges.first { $0.id == merge.id })
    try expect(updated.summary == merge.summary)
    try expect(!updated.sourceRecordIDs.contains(id))
    try expect(next.branches == db.branches && next.projects == db.projects)
    var repeating = db
    let i = try require(repeating.records.firstIndex { $0.kind == .meeting })
    repeating.records[i].repeatRule = .weekly
    try expect(try repeating.deletionPreview(.record(repeating.records[i].id)).detail.contains("整个系列"))
    try expect(try repeating.deleting(.record(repeating.records[i].id)).record(repeating.records[i].id) == nil)
    try next.validate()
}

@MainActor func deletionPersistsAndBackupRestores() throws {
    let db = Workspace.demo()
    let merge = try require(db.merges.first)
    let next = try db.deleting(.merge(merge.id))
    try expect(next.records == db.records && next.branches == db.branches)
    try expect(next.merges.count == db.merges.count - 1)
    let repository = try WorkspaceRepository(inMemory: true)
    try repository.save(db)
    let backup = try db.encoded()
    try repository.save(next)
    try expect(try repository.load()?.encoded() == next.encoded())
    try repository.save(Workspace.decoded(backup))
    try expect(try repository.load()?.encoded() == db.encoded())
    try expectThrows { _ = try db.deleting(.project(UUID())) }
    try expectThrows { _ = try db.deleting(.branch(UUID())) }
    try expectThrows { _ = try db.deleting(.record(UUID())) }
    try expectThrows { _ = try db.deleting(.merge(UUID())) }
    var empty = Workspace(); let project = Project(title: "空项目"); empty.projects = [project]
    try expect(try empty.deleting(.project(project.id)).projects.isEmpty)
}
