import Foundation

public struct ReviewEntry: Identifiable, Codable, Equatable, Sendable {
    public var kind: SearchEntity
    public var entityID: UUID
    public var occurrence: Date?
    public var title: String
    public var body: String
    public var date: Date?
    public var materials: [MaterialLink]? = nil
    public var id: String { "\(kind.rawValue)-\(entityID)-\(occurrence?.timeIntervalSince1970 ?? 0)" }
    public var sourceURL: String {
        "branchline://\(kind.rawValue)/\(entityID)" + (occurrence.map { "?occurrence=\(floor($0.timeIntervalSince1970))" } ?? "")
    }
}
public enum ReviewFormat: String, CaseIterable, Codable, Sendable {
    case brief = "精简周报", detailed = "完整回顾"
}

public struct ReviewGroup: Codable, Equatable, Sendable {
    public var projectID: UUID?
    public var title: String
}

public struct ReviewSection: Identifiable, Codable, Equatable, Sendable {
    public var title: String
    public var entries: [ReviewEntry]
    public var group: ReviewGroup? = nil
    public var id: String { (group?.projectID?.uuidString ?? "") + ":" + title }
}
public struct ReviewScope: Codable, Equatable, Sendable {
    public var from: Date
    public var through: Date
    public var projectID: UUID?
    public var branchID: UUID?
    public func matches(from: Date, through: Date, projectID: UUID?, branchID: UUID?, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self.from, inSameDayAs: from) && calendar.isDate(self.through, inSameDayAs: through) && self.projectID == projectID && self.branchID == branchID
    }
}
public struct WorkReview: Codable, Equatable, Sendable {
    public var title: String
    public var sections: [ReviewSection]
    public var scope: ReviewScope? = nil
    public var format: ReviewFormat? = nil
    public var style: ReviewFormat { format ?? .detailed }
    public var markdown: String {
        var blocks = ["# " + title]
        var group: ReviewGroup?
        for section in sections {
            if let next = section.group, group != next {
                blocks.append("## " + MaterialLink.label(next.title))
                group = next
            }
            let heading = section.group == nil ? "## " : "### "
            let items = section.entries.map { entry in
                let date = entry.date.map { Self.day($0) + " · " } ?? ""
                let title = entry.title.replacingOccurrences(of: "\n", with: " ")
                let caption = style == .brief ? "[\(MaterialLink.label(title))](\(entry.sourceURL))" : title
                var lines = entry.body.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
                if lines == [""] { lines = [] }
                if let materials = entry.materials, !materials.isEmpty {
                    lines.append("相关资料　" + materials.map(\.markdown).joined(separator: " · "))
                }
                return (["- " + date + caption] + lines.map { "  " + $0 }).joined(separator: "\n")
            }
            blocks.append(heading + section.title + "\n\n" + (items.isEmpty ? "无" : items.joined(separator: "\n\n")))
        }
        if sections.isEmpty { blocks.append("该范围内暂无可汇报条目。") }
        return blocks.joined(separator: "\n\n") + "\n"
    }
    public var sourceAppendix: String {
        var seen = Set<String>()
        let entries = sections.flatMap(\.entries).filter { seen.insert($0.id).inserted }
        guard !entries.isEmpty else { return "" }
        return "\n## 来源\n\n" + entries.map { entry in
            let label = MaterialLink.label((entry.date.map { Self.day($0) + " · " } ?? "") + entry.title)
            return "- [\(label)](\(entry.sourceURL))"
        }.joined(separator: "\n") + "\n"
    }
    private static func day(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }
}
extension Workspace {
    public func review(from: Date, through: Date, projectID: UUID?, branchID: UUID?, now: Date = Date(), calendar: Calendar = .current, format: ReviewFormat = .detailed) throws -> WorkReview {
        guard calendar.startOfDay(for: from) <= calendar.startOfDay(for: through), let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)) else { throw WorkspaceError("开始日期不能晚于结束日期。") }
        let start = calendar.startOfDay(for: from)
        guard calendar.dateComponents([.day], from: start, to: end).day! <= 366 else { throw WorkspaceError("一次回顾最多选择一年，请缩短日期范围。") }
        func within(_ date: Date?) -> Bool { date.map { $0 >= start && $0 < end } ?? false }
        let scoped = records.filter { (projectID == nil || projects(for: $0).contains(projectID!)) && (branchID == nil || $0.branchID == branchID) }
        func entry(_ record: WorkRecord, date: Date?, occurrence: Date? = nil) -> ReviewEntry {
            ReviewEntry(kind: .record, entityID: record.id, occurrence: occurrence, title: record.title, body: record.body, date: date, materials: record.materials)
        }
        func sorted(_ values: [ReviewEntry]) -> [ReviewEntry] { values.sorted { $0.date == $1.date ? $0.id < $1.id : ($0.date ?? .distantPast) < ($1.date ?? .distantPast) } }
        let progress = scoped.filter { $0.kind == .progress && within($0.startAt) }.map { entry($0, date: $0.startAt) }
        let completed = scoped.filter { $0.kind == .task && $0.status == .completed && within($0.completedAt) }.map { entry($0, date: $0.completedAt) }
        let scopedMerges = merges.filter {
            (projectID == nil || $0.projectID == projectID || branch($0.targetBranchID)?.projectIDs.contains(projectID!) == true) &&
            (branchID == nil || $0.branchID == branchID) && within($0.date)
        }
        let outcomes = scopedMerges.map { ReviewEntry(kind: .merge, entityID: $0.id, title: $0.summary, body: (branch($0.branchID)?.title ?? "分支") + " → " + mergeTargetTitle($0), date: $0.date) }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        let scope = branchID.flatMap { branch($0)?.title } ?? projectID.flatMap { project($0)?.title } ?? "全部项目与独立分支"
        let title = "\(scope) · \(f.string(from: start)) 至 \(f.string(from: through))"
        let reportScope = ReviewScope(from: start, through: through, projectID: projectID, branchID: branchID)
        if format == .brief {
            let nextWeekEnd = calendar.date(byAdding: .day, value: 7, to: end)!
            let nextWeekLastDay = calendar.date(byAdding: .day, value: 6, to: end)!
            var recordsByID = [UUID: WorkRecord]()
            for record in records { recordsByID[record.id] = record }
            let unfinished = scoped.filter { $0.kind == .task && ($0.status == .active || $0.status == .paused) }
            let blocked = unfinished.compactMap { task -> ReviewEntry? in
                let dependencies = task.dependencies.compactMap { recordsByID[$0] }.filter { $0.status != .completed }
                guard !dependencies.isEmpty else { return nil }
                var value = entry(task, date: task.dueAt)
                value.body = "等待 " + dependencies.map { "[\(MaterialLink.label($0.title))](branchline://record/\($0.id))" }.joined(separator: "、")
                return value
            }
            let due = unfinished.compactMap { task -> ReviewEntry? in
                guard let date = task.dueAt, date >= end, date < nextWeekEnd else { return nil }
                var value = entry(task, date: date)
                value.body = ""
                return value
            }
            let mergeProjects = Dictionary(uniqueKeysWithValues: scopedMerges.map { merge in
                (merge.id, merge.projectID.map { [$0] } ?? branch(merge.targetBranchID)?.projectIDs ?? [])
            })
            let recordProjects = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, projects(for: $0)) })
            var groups = projects.filter { projectID == nil || $0.id == projectID }.map { ReviewGroup(projectID: $0.id, title: $0.title) }
            if projectID == nil { groups.append(ReviewGroup(title: "独立分支")) }
            let recent = sorted(progress + completed).reversed()
            let sections = groups.flatMap { group -> [ReviewSection] in
                func belongs(_ entry: ReviewEntry) -> Bool {
                    let ids = (entry.kind == .merge ? mergeProjects[entry.entityID] : recordProjects[entry.entityID]) ?? []
                    return group.projectID.map { ids.contains($0) } ?? ids.isEmpty
                }
                let keyProgress = Array(recent.lazy.filter(belongs).prefix(3)).map { entry in
                    var summary = entry
                    summary.body = ""
                    return summary
                }
                let nextTitle = "下周到期（\(f.string(from: end)) 至 \(f.string(from: nextWeekLastDay))）"
                return [
                    ReviewSection(title: "关键进展", entries: keyProgress, group: group),
                    ReviewSection(title: "阶段成果", entries: sorted(outcomes.filter(belongs)), group: group),
                    ReviewSection(title: "当前阻塞", entries: sorted(blocked.filter(belongs)), group: group),
                    ReviewSection(title: nextTitle, entries: sorted(due.filter(belongs)), group: group)
                ].filter { !$0.entries.isEmpty }
            }
            return WorkReview(title: title, sections: sections, scope: reportScope, format: .brief)
        }
        let meetings = scoped.filter { $0.kind == .meeting }.flatMap { record in
            CalendarLogic.occurrences(of: record, in: DateInterval(start: start, end: end)).filter { $0 < end }.map { entry(record, date: $0, occurrence: $0) }
        }
        let cancelled = Set(scoped.filter { $0.calendarLink?.disposition == .cancelled }.map(\.id))
        let overdue = scoped.filter { $0.kind == .task && CalendarLogic.deadlinePassed($0, now: now) }.map { entry($0, date: $0.dueAt) }
        let pending = scoped.filter { $0.kind == .task && ($0.status == .active || $0.status == .paused) && !CalendarLogic.deadlinePassed($0, now: now) }.map { entry($0, date: $0.dueAt) }
        let backfilled = scoped.filter { within($0.createdAt) && $0.kind == .progress && $0.startAt < start }.map { entry($0, date: $0.startAt) }
        let unknownCompletion = scoped.filter { $0.kind == .task && $0.status == .completed && $0.completedAt == nil }.map { entry($0, date: nil) }
        var sections = [ReviewSection(title: "期间发生的进展", entries: sorted(progress)), ReviewSection(title: "期间实际完成的任务", entries: sorted(completed)), ReviewSection(title: "期间阶段成果", entries: sorted(outcomes)), ReviewSection(title: "已发生会议", entries: sorted(meetings.filter { ($0.date ?? .distantFuture) <= now && !cancelled.contains($0.entityID) })), ReviewSection(title: "后续会议安排", entries: sorted(meetings.filter { ($0.date ?? .distantPast) > now && !cancelled.contains($0.entityID) })), ReviewSection(title: "当前逾期（截至 \(f.string(from: now))）", entries: sorted(overdue)), ReviewSection(title: "当前待处理（含暂停）", entries: sorted(pending))]
        if meetings.contains(where: { cancelled.contains($0.entityID) }) { sections.append(ReviewSection(title: "已取消会议", entries: sorted(meetings.filter { cancelled.contains($0.entityID) }))) }
        if !backfilled.isEmpty { sections.append(ReviewSection(title: "本期录入的历史补记（未计入本期进展）", entries: sorted(backfilled))) }
        if !unknownCompletion.isEmpty { sections.append(ReviewSection(title: "已完成但缺少完成日期（未计入本期完成）", entries: sorted(unknownCompletion))) }
        return WorkReview(title: title, sections: sections, scope: reportScope)
    }
}
