import Foundation
import ProgressCore

func nestedBranchesMergeAndValidate() throws {
    var db = Workspace.demo()
    let parent = db.branches[0]
    var child = Branch(title: "子分支", projectIDs: parent.projectIDs)
    child.originBranchID = parent.id; child.startAt = parent.startAt.addingTimeInterval(86400)
    db.branches.append(child)
    var parentMerge = MergeRecord(branchID: child.id, targetBranchID: parent.id, summary: "回到父分支")
    parentMerge.date = child.startAt.addingTimeInterval(86400)
    var mainMerge = MergeRecord(branchID: child.id, projectID: parent.projectIDs[0], summary: "回到主干")
    mainMerge.date = parentMerge.date
    db.merges += [parentMerge, mainMerge]
    try db.validate()
    let restored = try Workspace.decoded(db.encoded())
    try expect(restored.branch(child.id)?.originBranchID == parent.id)
    try expect(restored.merges.first { $0.id == parentMerge.id }?.targetBranchID == parent.id)
    let rows = db.roadmap(projectIDs: Set(db.projects.map(\.id)), collapsed: [], records: db.records, includeIndependent: true)
    try expect(rows.flatMap(\.events).contains { $0.entityID == child.id && $0.sourceLaneID == parent.id })
    try expect(rows.flatMap(\.events).contains { $0.entityID == parentMerge.id && $0.laneID == parent.id && $0.sourceLaneID == child.id })
    var bad = db; bad.branches[0].originProjectID = nil; bad.branches[0].originBranchID = child.id
    try expectThrows { try bad.validate() }
    bad = db; bad.branches[bad.branches.count - 1].startAt = parent.startAt.addingTimeInterval(-86400)
    try expectThrows { try bad.validate() }
    bad = db; bad.branches[0].closedAt = parentMerge.date.addingTimeInterval(-86400)
    try expectThrows { try bad.validate() }
    bad = db; bad.merges[bad.merges.count - 2].targetBranchID = db.branches[1].id
    try expectThrows { try bad.validate() }
    // Old exports have neither of the new optional relationship fields.
    var legacyWorkspace = Workspace.demo()
    legacyWorkspace.merges.removeAll { $0.targetBranchID != nil }
    var legacy = try JSONSerialization.jsonObject(with: legacyWorkspace.encoded()) as! [String: Any]
    legacy["branches"] = (legacy["branches"] as! [[String: Any]]).map { entry in var copy = entry; copy.removeValue(forKey: "originBranchID"); return copy }
    legacy["merges"] = (legacy["merges"] as! [[String: Any]]).map { entry in var copy = entry; copy.removeValue(forKey: "targetBranchID"); return copy }
    try expect(try Workspace.decoded(JSONSerialization.data(withJSONObject: legacy)).merges.count == legacyWorkspace.merges.count)
}

func deletingParentPreservesChildren() throws {
    var db = Workspace.demo()
    let parent = db.branches[0]
    var child = Branch(title: "共享子分支", projectIDs: db.projects.prefix(2).map(\.id))
    child.originBranchID = parent.id; child.startAt = parent.startAt
    db.branches.append(child)
    var record = WorkRecord(title: "子分支记录"); record.branchID = child.id; db.records.append(record)
    let merge = MergeRecord(branchID: child.id, targetBranchID: parent.id, summary: "子成果")
    db.merges.append(merge)
    let branchDeleted = try db.deleting(.branch(parent.id))
    try expect(branchDeleted.branch(child.id)?.originBranchID == nil)
    try expect(branchDeleted.record(record.id) != nil)
    try expect(!branchDeleted.merges.contains { $0.id == merge.id })
    let projectDeleted = try db.deleting(.project(parent.projectIDs[0]))
    try expect(projectDeleted.branch(child.id)?.originBranchID == nil)
    try expect(projectDeleted.branch(child.id)?.projectIDs.count == 1)
    try expect(projectDeleted.record(record.id) != nil)
}

func routeOrderPersistsWithoutChangingRelationships() throws {
    var db = Workspace.demo()
    let first = db.projects[0], last = db.projects.last!
    let moved = try db.reordering(first.id, relativeTo: last.id, after: true)
    try expect(moved.projects.last?.id == first.id)
    try expect(moved.branches == db.branches && moved.records == db.records && moved.merges == db.merges)
    let restored = try Workspace.decoded(moved.encoded())
    try expect(restored.projects.map(\.id) == moved.projects.map(\.id))
    let a = db.branches[0], shared = db.branches.first { $0.projectIDs.count > 1 }!
    let reordered = try db.reordering(a.id, relativeTo: shared.id, after: true)
    try expect(reordered.branches.firstIndex { $0.id == a.id }! > reordered.branches.firstIndex { $0.id == shared.id }!)
    try expect(reordered.branches.allSatisfy { db.branch($0.id) == $0 })
    let before = try reordered.reordering(a.id, relativeTo: shared.id, after: false)
    try expect(before.branches.firstIndex { $0.id == a.id }! + 1 == before.branches.firstIndex { $0.id == shared.id }!)
    try expectThrows { _ = try db.reordering(first.id, relativeTo: a.id, after: true) }
    let unrelated = db.branches.first { Set($0.projectIDs).isDisjoint(with: a.projectIDs) }!
    try expectThrows { _ = try db.reordering(a.id, relativeTo: unrelated.id, after: true) }
    try expectThrows { _ = try db.reordering(first.id, relativeTo: first.id, after: true) }
    let independentA = Branch(title: "独立 A"), independentB = Branch(title: "独立 B")
    db.branches += [independentA, independentB]
    try expect(try db.reordering(independentA.id, relativeTo: independentB.id, after: true).branches.last?.id == independentA.id)
}
