import Foundation
import ProgressCore

@MainActor func reviewPresetsRollForwardKeepingDraft() throws {
    let dates = ISO8601DateFormatter()
    let sunday = dates.date(from: "2026-11-29T09:00:00Z")!
    let monday = dates.date(from: "2026-11-30T09:00:00Z")!
    let december = dates.date(from: "2026-12-01T09:00:00Z")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let weeklyRange = try require(ReviewPreset.week.range(now: sunday, calendar: calendar))
    let workspace = Workspace.demo(now: sunday)
    var draft = ReviewDraft(preset: ReviewPreset.week.rawValue, from: weeklyRange.0, through: weeklyRange.1)
    let original = try workspace.review(from: draft.from, through: draft.through, projectID: nil, branchID: nil, now: sunday, calendar: calendar)
    draft.replace(with: original)
    draft.text += "\n手工整理的上期正文。"
    let edited = draft.text
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("review-period-\(UUID())/review.json")
    let repository = ReviewDraftRepository(url: file)
    try repository.save(draft)
    draft = try require(repository.load())
    draft.refreshPresetDates(now: monday, calendar: calendar)
    try expect(draft.from == calendar.startOfDay(for: monday))
    try expect(draft.text == edited && draft.report == original && draft.hasManualChanges)
    let current = try workspace.review(from: draft.from, through: draft.through, projectID: nil, branchID: nil, now: monday, calendar: calendar, format: .brief)
    try expect(current.scope?.from == draft.from)
    draft.replace(with: current)
    draft.undoReplacement()
    try expect(draft.text == edited && draft.report == original)
    draft.preset = ReviewPreset.month.rawValue
    draft.refreshPresetDates(now: december, calendar: calendar)
    try expect(draft.from == calendar.startOfDay(for: december))
    try expect(calendar.component(.day, from: draft.through) == 31)
    draft.preset = ReviewPreset.custom.rawValue
    let datesBefore = (draft.from, draft.through)
    draft.refreshPresetDates(now: sunday, calendar: calendar)
    try expect(draft.from == datesBefore.0 && draft.through == datesBefore.1)
}

@MainActor func briefReviewGroupsWorkAndCarriesMaterials() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let from = ISO8601DateFormatter().date(from: "2026-11-16T00:00:00Z")!
    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: from)! }
    var workspace = Workspace()
    var pump = Project(title: "微泵")
    var paper = Project(title: "样机论文")
    pump.createdAt = day(-14); paper.createdAt = day(-14)
    var shared = Branch(title: "流量标定", projectIDs: [pump.id, paper.id])
    shared.startAt = day(-7)
    workspace.projects = [pump, paper]; workspace.branches = [shared]
    let local = try require(MaterialLink(address: "/tmp/标定数据 (第 1 轮).csv"))
    let web = try require(MaterialLink(address: "https://example.com/data?view=week&n=1", title: "数据 [汇总]"))
    try expect(MaterialLink(address: "branchline://record/123") == nil)
    for offset in 0...4 {
        var entry = WorkRecord(title: "流量记录 \(offset)")
        entry.branchID = shared.id; entry.startAt = day(offset)
        if offset == 4 { entry.materials = [local, web] }
        try workspace.putRecord(entry)
    }
    let latest = try require(workspace.records.last)
    var result = MergeRecord(branchID: shared.id, projectID: pump.id, summary: "标定数据筛选完成", sourceRecordIDs: [latest.id])
    result.date = day(5)
    try workspace.addMerge(result)
    var dependency = WorkRecord(kind: .task, title: "检查流量计")
    dependency.projectIDs = [paper.id]
    try workspace.putRecord(dependency)
    var task = WorkRecord(kind: .task, title: "整理误差表")
    task.projectIDs = [pump.id]; task.dueAt = day(7); task.dependencies = [dependency.id]
    try workspace.putRecord(task)
    var later = WorkRecord(kind: .task, title: "再下一周到期")
    later.projectIDs = [pump.id]; later.dueAt = day(14)
    try workspace.putRecord(later)
    try workspace.validate()
    let report = try workspace.review(from: from, through: day(6), projectID: nil, branchID: nil, now: day(5), calendar: calendar, format: .brief)
    let recent = report.sections.filter { $0.title == "关键进展" }
    try expect(recent.count == 2 && recent.allSatisfy { $0.entries.count == 3 && $0.entries.first?.entityID == latest.id })
    try expect(report.sections.first { $0.title == "阶段成果" }?.group?.projectID == pump.id)
    try expect(report.sections.first { $0.title == "当前阻塞" }?.entries.first?.body.contains(dependency.id.uuidString) == true)
    try expect(report.sections.first { $0.title.hasPrefix("下周到期") }?.entries.map(\.entityID) == [task.id])
    let reportBody = try AttributedString(markdown: report.markdown)
    let links = Set(reportBody.runs.compactMap(\.link))
    try expect(links.contains(local.url) && links.contains(web.url))
    try expect(report.sourceAppendix.components(separatedBy: latest.id.uuidString).count == 2)
    let detailed = try workspace.review(from: from, through: day(6), projectID: pump.id, branchID: nil, now: day(5), calendar: calendar)
    try expect(detailed.markdown.contains(local.url.absoluteString))
    let recordData = try JSONEncoder().encode(latest)
    try expect(JSONDecoder().decode(WorkRecord.self, from: recordData).materials == [local, web])
}

@MainActor func reminderQueueRefillsAndTargetsEditedOccurrence() throws {
    let now = ISO8601DateFormatter().date(from: "2026-11-18T02:00:00Z")!
    var workspace = Workspace()
    let project = Project(title: "提醒续排")
    workspace.projects = [project]
    var meeting = WorkRecord(kind: .meeting, title: "日常检查")
    meeting.timeZoneID = "UTC"; meeting.projectIDs = [project.id]
    meeting.startAt = now.addingTimeInterval(3600); meeting.endAt = meeting.startAt.addingTimeInterval(1800)
    meeting.repeatRule = .daily; meeting.relativeReminders = [.start15Minutes]
    try workspace.putRecord(meeting)
    let initial = workspace.reminderQueue(now: now)
    try expect(initial.scheduled.count == 64 && initial.hasMore)
    let first = try require(initial.scheduled.first)
    let refill = workspace.reminderQueue(now: first.fireDate.addingTimeInterval(1))
    try expect(refill.scheduled.count == 64 && refill.hasMore)
    try expect(refill.scheduled.dropLast().map(\.id) == initial.scheduled.dropFirst().map(\.id))
    let occurrence = try require(refill.scheduled.first?.target.occurrence)
    var moved = meeting.occurrenceDraft(at: occurrence)
    moved.startAt.addTimeInterval(7200); moved.endAt = moved.startAt.addingTimeInterval(1800)
    let revised = try workspace.editingRecurring(meeting.id, occurrence: occurrence, input: moved, scope: .occurrence)
    let updated = revised.reminderQueue(now: first.fireDate.addingTimeInterval(1))
    let scheduled = try require(updated.scheduled.first)
    try expect(scheduled.target.occurrence == moved.startAt && scheduled.target.recordID != meeting.id)
    try expect(revised.reminderDestination(for: scheduled.target)?.focusDate == moved.startAt)
    try expect(!updated.scheduled.contains { $0.id == refill.scheduled.first?.id })
}
