import Foundation
import ProgressCore

func recordingContextNeverGuessesFirstDestination() throws {
    let db = Workspace.demo()
    try expect(db.recordingLocation(context: nil, projectFilter: nil) == nil)
    let branch = try require(db.branches.first { $0.projectIDs.count > 1 })
    let other = try require(db.projects.first { !branch.projectIDs.contains($0.id) && $0.status != .archived })
    let branchLocation = RecordingLocation(branchID: branch.id)
    let explicit = RecordingLocation(projectIDs: [other.id])
    try expect(db.recordingLocation(explicit: explicit, context: .branch(branch.id), projectFilter: branch.projectIDs[0]) == explicit)
    try expect(db.recordingLocation(context: .branch(branch.id), projectFilter: branch.projectIDs[0]) == branchLocation)
    // A stale selection from another project cannot override the current project filter.
    try expect(db.recordingLocation(context: .branch(branch.id), projectFilter: other.id) == explicit)
    try expect(db.recordingLocation(explicit: RecordingLocation(branchID: UUID()), context: .branch(branch.id), projectFilter: other.id) == nil)
}
func recordingContextFollowsSelectedRecordAndMerge() throws {
    var db = Workspace.demo()
    let branch = try require(db.branches.first { $0.projectIDs.count > 1 })
    var record = WorkRecord(title: "共享记录"); record.branchID = branch.id; db.records.append(record)
    let branchLocation = RecordingLocation(branchID: branch.id)
    try expect(db.recordingLocation(context: .record(record.id), projectFilter: nil) == branchLocation)
    record.branchID = nil; record.projectIDs = branch.projectIDs; db.records[db.records.count - 1] = record
    try expect(db.recordingLocation(context: .record(record.id), projectFilter: branch.projectIDs[0]) == RecordingLocation(projectIDs: branch.projectIDs))
    let merge = db.merges[0]
    try expect(db.recordingLocation(context: .merge(merge.id), projectFilter: nil) == RecordingLocation(branchID: merge.branchID))
    let independent = try require(db.branches.first { $0.projectIDs.isEmpty })
    try expect(db.recordingLocation(context: .branch(independent.id), projectFilter: nil) == RecordingLocation(branchID: independent.id))
    try expect(branchLocation.detail(in: db).contains(db.project(branch.projectIDs[0])!.title))
    try expect(branchLocation.detail(in: db).contains(db.project(branch.projectIDs[1])!.title))
}
func archivedAndDeletedLocationsCannotBecomeImplicitDefaults() throws {
    var db = Workspace.demo()
    let branch = db.branches[0]; let location = RecordingLocation(branchID: branch.id)
    let other = RecordingLocation(projectIDs: [db.projects[1].id])
    let encoded = try JSONEncoder().encode([location, other])
    let history = try JSONDecoder().decode([RecordingLocation].self, from: encoded)
    try expect(db.lastRecordingLocation(in: history) == location)
    db.branches[0].status = .archived
    try expect(db.lastRecordingLocation(in: history) == nil)
    try expect(db.recordingLocation(context: .branch(branch.id), projectFilter: nil) == nil)
    // An explicit user choice may still target archived work.
    try expect(db.recordingLocation(explicit: location, context: nil, projectFilter: nil) == location)
    db.branches.removeFirst()
    try expect(db.lastRecordingLocation(in: history) == nil && !location.exists(in: db))
    let archived = try require(db.projects.first { $0.status == .archived })
    try expect(db.recordingLocation(context: .project(archived.id), projectFilter: archived.id) == nil)
}
func choosingLocationPreservesContentDatesAndSettings() throws {
    let db = Workspace.demo()
    var record = WorkRecord(title: "一句话"); record.body = "长正文\n第二行"; record.dateOnly = false
    record.startAt = ISO8601DateFormatter().date(from: "2026-10-26T02:23:00Z")!; record.relativeReminders = [.start15Minutes]
    let original = record
    let branch = RecordingLocation(branchID: db.branches[0].id)
    record = branch.applying(to: record)
    try expect(record.title == original.title && record.body == original.body && record.startAt == original.startAt && record.relativeReminders == original.relativeReminders && !record.dateOnly)
    try expect(record.branchID == db.branches[0].id && record.projectIDs.isEmpty)
    let projects = RecordingLocation(projectIDs: [db.projects[1].id, db.projects[0].id, db.projects[1].id])
    record = projects.applying(to: record)
    try expect(record.branchID == nil && Set(record.projectIDs) == Set([db.projects[0].id, db.projects[1].id]))
    try expect(record.recordingLocation == projects)
}
