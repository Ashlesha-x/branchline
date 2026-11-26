import Foundation

public enum WorkStatus: String, Codable, CaseIterable, Sendable {
    case active, paused, completed, archived
    public var title: String {
        switch self { case .active: "进行中"; case .paused: "已暂停"; case .completed: "已完成"; case .archived: "已归档" }
    }
}
public enum RecordKind: String, Codable, CaseIterable, Sendable {
    case progress, task, meeting
    public var title: String { switch self { case .progress: "进度"; case .task: "任务"; case .meeting: "会议" } }
    public var symbol: String { switch self { case .progress: "text.bubble"; case .task: "checklist"; case .meeting: "calendar" } }
}
public enum RepeatRule: String, Codable, CaseIterable, Sendable {
    case none, daily, weekly, monthly
    public var title: String { switch self { case .none: "不重复"; case .daily: "每天"; case .weekly: "每周"; case .monthly: "每月" } }
}
public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title = ""
    public var note = ""
    public var status: WorkStatus = .active
    public var color = 0
    public var createdAt = Date()
    public var closedAt: Date?
    public var archivedAt: Date?
    public init(title: String = "", color: Int = 0) { self.title = title; self.color = color }
}
public struct Branch: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title = ""
    public var note = ""
    public var projectIDs: [UUID] = []
    public var originProjectID: UUID?
    public var originBranchID: UUID?
    public var startAt = Date()
    public var closedAt: Date?
    public var archivedAt: Date?
    public var status: WorkStatus = .active
    public var color = 2
    public init(title: String = "", projectIDs: [UUID] = []) { self.title = title; self.projectIDs = projectIDs }
}
public struct WorkRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: RecordKind = .progress
    public var title = ""
    public var body = ""
    public var materials: [MaterialLink]?
    public var projectIDs: [UUID] = []
    public var branchID: UUID?
    public var startAt = Date()
    public var dateOnly = true
    public var endAt: Date?
    public var dueAt: Date?
    public var dueDateOnly = true
    public var completedAt: Date?
    public var status: WorkStatus = .active
    public var reminderDates: [Date] = []
    public var relativeReminders: [RelativeReminder]?
    public var taskScheduled: Bool?
    public var dependencies: [UUID] = []
    public var repeatRule: RepeatRule = .none
    public var repeatUntil: Date?
    public var recurrenceAnchor: Date?
    public var excludedOccurrences: [Date]?
    public var seriesID: UUID?
    public var originalOccurrence: Date?
    public var createdAt = Date()
    public var updatedAt = Date()
    public var timeZoneID = TimeZone.current.identifier
    public var taskSeriesID: UUID?
    public var taskOccurrence: Date?
    public var taskRepeatRule: RepeatRule?
    public var taskRepeatUntil: Date?
    public var calendarLink: CalendarEventLink?
    public init(kind: RecordKind = .progress, title: String = "") { self.kind = kind; self.title = title; self.dateOnly = kind != .meeting; self.taskScheduled = kind == .task ? false : nil }
}
public struct MergeRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var branchID: UUID
    public var projectID: UUID?
    public var targetBranchID: UUID?
    public var targetLaneID: UUID? { targetBranchID ?? projectID }
    public var date = Date()
    public var summary: String
    public var sourceRecordIDs: [UUID]
    public var closesBranch = false
    public init(branchID: UUID, projectID: UUID, summary: String, sourceRecordIDs: [UUID] = []) {
        self.branchID = branchID; self.projectID = projectID; self.summary = summary; self.sourceRecordIDs = sourceRecordIDs
    }
    public init(branchID: UUID, targetBranchID: UUID, summary: String, sourceRecordIDs: [UUID] = []) {
        self.branchID = branchID; self.targetBranchID = targetBranchID; self.summary = summary; self.sourceRecordIDs = sourceRecordIDs
    }
}
public struct ChangeRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var entityID: UUID
    public var date = Date()
    public var summary: String
    public init(entityID: UUID, summary: String) { self.entityID = entityID; self.summary = summary }
}
public struct Workspace: Codable, Equatable, Sendable {
    public var version = 4
    public var projects: [Project] = []
    public var branches: [Branch] = []
    public var records: [WorkRecord] = []
    public var merges: [MergeRecord] = []
    public var history: [ChangeRecord] = []
    public var taskPlans: [TaskPlan]?
    public var automationReceipts: [OperationReceipt]?
    public var trashEntries: [TrashEntry]?
    public var trash: [TrashEntry] { trashEntries ?? [] }
    public init() {}
    public func project(_ id: UUID?) -> Project? { projects.first { $0.id == id } }
    public func branch(_ id: UUID?) -> Branch? { branches.first { $0.id == id } }
    public func record(_ id: UUID?) -> WorkRecord? { records.first { $0.id == id } }
    public func mergeTargetTitle(_ merge: MergeRecord) -> String { branch(merge.targetBranchID)?.title ?? project(merge.projectID)?.title ?? "已移除目标" }
    public func branchAncestors(_ id: UUID) -> Set<UUID> {
        var result = Set<UUID>(), next = branch(id)?.originBranchID
        while let current = next, result.insert(current).inserted { next = branch(current)?.originBranchID }
        return result
    }
    public func projects(for record: WorkRecord) -> [UUID] {
        if let branch = branch(record.branchID) { return branch.projectIDs }
        return record.projectIDs
    }
    public func blockedBy(_ record: WorkRecord) -> [WorkRecord] {
        records.filter { record.dependencies.contains($0.id) && $0.status != .completed }
    }
}
public struct WorkspaceError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

extension Workspace {
    public func validate() throws { try validate(strictDayOrder: []) }
    /// Day-order rules compare calendar days, which depend on the Mac's current time zone.
    /// Entities in `strictDayOrder` are checked by the current calendar; all others use a
    /// zone-independent bound (strictly less than one day earlier), so travelling or changing
    /// the system time zone never makes already-saved data invalid.
    public func validate(strictDayOrder strict: Set<UUID>) throws {
        guard version == 4 else { throw WorkspaceError("不支持这份备份的数据版本，请使用对应版本的应用。") }
        guard Set(trash.map(\.id)).count == trash.count else { throw WorkspaceError("回收站标识重复。") }
        for entry in trash { try entry.validate() }
        let ids = projects.map(\.id) + branches.map(\.id) + records.map(\.id) + merges.map(\.id) + history.map(\.id) + (taskPlans ?? []).map(\.id)
        guard Set(ids).count == ids.count else { throw WorkspaceError("数据包含重复标识，未写入。") }
        let projectIDs = Set(projects.map(\.id)), branchIDs = Set(branches.map(\.id)), recordIDs = Set(records.map(\.id))
        for project in projects {
            try requireTitle(project.title)
            guard RouteColors.isValid(project.color) else { throw WorkspaceError("项目颜色无效。") }
            try validateClosure(title: project.title, start: project.createdAt, end: project.closedAt, archive: project.archivedAt, latestMerge: merges.filter { $0.projectID == project.id }.map(\.date).max(), strict: strict.contains(project.id))
        }
        for branch in branches {
            try requireTitle(branch.title)
            guard RouteColors.isValid(branch.color), Set(branch.projectIDs).isSubset(of: projectIDs), Set(branch.projectIDs).count == branch.projectIDs.count else { throw WorkspaceError("分支的项目关联或颜色无效。") }
            if let origin = branch.originProjectID, !branch.projectIDs.contains(origin) { throw WorkspaceError("分支起点必须属于关联项目。") }
            if let parentID = branch.originBranchID {
                guard branch.originProjectID == nil, let parent = self.branch(parentID), !branchAncestors(branch.id).contains(branch.id) else { throw WorkspaceError("父分支不存在或分支关系形成循环。") }
                guard Self.dayNotBefore(branch.startAt, parent.startAt, strict: strict.contains(branch.id)) else { throw WorkspaceError("子分支开始日期不能早于父分支。") }
            }
            try validateClosure(title: branch.title, start: branch.startAt, end: branch.closedAt, archive: branch.archivedAt, latestMerge: merges.filter { $0.branchID == branch.id || $0.targetBranchID == branch.id }.map(\.date).max(), strict: strict.contains(branch.id))
        }
        try validateTaskPlans()
        for record in records {
            try requireTitle(record.title)
            try record.validateMaterials()
            guard Set(record.projectIDs).isSubset(of: projectIDs), record.branchID.map({ branchIDs.contains($0) }) ?? true else { throw WorkspaceError("记录关联的项目或分支不存在。") }
            guard record.branchID != nil || !record.projectIDs.isEmpty else { throw WorkspaceError("请选择一个项目或分支。") }
            if let end = record.endAt, end < record.startAt { throw WorkspaceError("结束时间不能早于开始时间。") }
            if let completed = record.completedAt, completed < record.startAt, record.kind != .task || record.hasPlannedStart { throw WorkspaceError("实际完成时间不能早于开始时间。") }
            if record.kind == .meeting && record.endAt == nil { throw WorkspaceError("会议需要结束时间。") }
            guard record.relativeRules.allSatisfy({ record.availableReminderRules.contains($0) }), Set(record.relativeRules).count == record.relativeRules.count else { throw WorkspaceError("相对提醒与记录的计划日期或截止日期不匹配。") }
            guard TimeZone(identifier: record.timeZoneID) != nil else { throw WorkspaceError("记录时区无效。") }
            guard Set(record.dependencies).isSubset(of: recordIDs), !record.dependencies.contains(record.id) else { throw WorkspaceError("任务依赖无效。") }
            if !record.dependencies.isEmpty && record.kind != .task { throw WorkspaceError("只有任务可以设置依赖。") }
            for id in record.dependencies where self.record(id)?.kind != .task { throw WorkspaceError("依赖对象必须是任务。") }
            if record.taskSeriesID != nil && (record.kind != .task || record.taskOccurrence == nil || !(taskPlans ?? []).contains(where: { $0.id == record.taskSeriesID })) { throw WorkspaceError("重复任务的计划关联无效。") }
            if record.repeatRule != .none && record.kind != .meeting { throw WorkspaceError("仅会议支持重复。") }
            if let parentID = record.seriesID {
                guard record.kind == .meeting, record.repeatRule == .none, record.originalOccurrence != nil,
                      let parent = self.record(parentID), parent.kind == .meeting, parent.repeatRule != .none,
                      parent.excludedOccurrences?.contains(record.originalOccurrence!) == true else { throw WorkspaceError("会议例外与重复系列的关联无效。") }
            } else if record.originalOccurrence != nil { throw WorkspaceError("会议例外缺少来源系列。") }
            guard Set(record.excludedOccurrences ?? []).count == (record.excludedOccurrences ?? []).count else { throw WorkspaceError("重复会议包含重复的例外日期。") }
            if record.repeatRule == .none && (record.repeatUntil != nil || record.recurrenceAnchor != nil || !(record.excludedOccurrences ?? []).isEmpty) { throw WorkspaceError("单次记录不能包含重复规则的边界。") }
            if let until = record.repeatUntil, until < record.startAt { throw WorkspaceError("重复结束边界不能早于系列开始。") }
        }
        let calendarKeys = records.compactMap { $0.calendarLink?.key }
        guard Set(calendarKeys).count == calendarKeys.count else { throw WorkspaceError("日历事件关联重复。") }
        let exceptionKeys = records.compactMap { item in item.seriesID.flatMap { parent in item.originalOccurrence.map { "\(parent)-\($0.timeIntervalSinceReferenceDate)" } } }
        guard Set(exceptionKeys).count == exceptionKeys.count else { throw WorkspaceError("同一次会议存在多个例外记录。") }
        for merge in merges {
            guard let branch = branch(merge.branchID) else { throw WorkspaceError("合并来源分支不存在。") }
            if let parentID = merge.targetBranchID {
                guard merge.projectID == nil, parentID == branch.originBranchID, let parent = self.branch(parentID) else { throw WorkspaceError("只能合并回当前父分支。") }
                guard merge.date >= parent.startAt else { throw WorkspaceError("合并时间不能早于父分支开始时间。") }
            } else {
                guard let projectID = merge.projectID, projectIDs.contains(projectID), branch.projectIDs.contains(projectID) else { throw WorkspaceError("合并目标必须是父分支或关联项目。") }
            }
            try requireTitle(merge.summary)
            guard merge.date >= branch.startAt else { throw WorkspaceError("合并时间不能早于分支开始时间。") }
            if let target = project(merge.projectID), !Self.dayNotBefore(merge.date, target.createdAt, strict: strict.contains(merge.id)) { throw WorkspaceError("合并日期不能早于目标项目开始日期。") }
            guard Set(merge.sourceRecordIDs).isSubset(of: recordIDs), merge.sourceRecordIDs.allSatisfy({ record($0)?.branchID == merge.branchID }) else { throw WorkspaceError("合并引用的记录必须属于来源分支。") }
        }
        var visiting = Set<UUID>(), finished = Set<UUID>()
        let edges = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.dependencies) })
        func visit(_ id: UUID) throws {
            if visiting.contains(id) { throw WorkspaceError("任务依赖形成循环，请移除其中一条依赖。") }
            if finished.contains(id) { return }
            visiting.insert(id)
            for dependency in edges[id] ?? [] { try visit(dependency) }
            visiting.remove(id); finished.insert(id)
        }
        for id in recordIDs { try visit(id) }
    }
    private func requireTitle(_ value: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw WorkspaceError("名称或摘要不能为空。") }
    }
    /// `later` falls on the same calendar day as `earlier` or after it. Non-strict checks accept
    /// any pair that is valid in some time zone: less than 24 hours earlier.
    public static func dayNotBefore(_ later: Date, _ earlier: Date, strict: Bool, calendar: Calendar = .current) -> Bool {
        if calendar.startOfDay(for: later) >= calendar.startOfDay(for: earlier) { return true }
        return !strict && later.timeIntervalSince(earlier) > -86_400
    }
    private func validateClosure(title: String, start: Date, end: Date?, archive: Date?, latestMerge: Date?, strict: Bool) throws {
        for (label, value) in [("结束", end), ("归档", archive)] {
            guard let value else { continue } // Older backups did not store closure dates.
            guard Self.dayNotBefore(value, start, strict: strict) else { throw WorkspaceError("「\(title)」的\(label)日期不能早于开始日期。") }
            if let latestMerge, !Self.dayNotBefore(value, latestMerge, strict: strict) { throw WorkspaceError("「\(title)」的\(label)日期不能早于最近一次合并日期（\(latestMerge.formatted(date: .numeric, time: .omitted))）。") }
        }
        if let end, let archive, !Self.dayNotBefore(archive, end, strict: strict) { throw WorkspaceError("「\(title)」的归档日期不能早于结束日期。") }
    }
    /// IDs whose day-order inputs differ from `old`; these are checked strictly on write.
    public func dayOrderChanges(since old: Workspace) -> Set<UUID> {
        var ids = Set<UUID>()
        for p in projects {
            let before = old.project(p.id)
            if before?.createdAt != p.createdAt || before?.closedAt != p.closedAt || before?.archivedAt != p.archivedAt { ids.insert(p.id) }
        }
        for b in branches {
            let before = old.branch(b.id)
            if before?.startAt != b.startAt || before?.closedAt != b.closedAt || before?.archivedAt != b.archivedAt || before?.originBranchID != b.originBranchID { ids.insert(b.id) }
        }
        let oldMerges = Dictionary(old.merges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in merges where oldMerges[m.id] != m {
            ids.insert(m.id)
            ids.insert(m.branchID)
            if let target = m.targetBranchID { ids.insert(target) }
            if let target = m.projectID { ids.insert(target) }
        }
        return ids
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    public static func decoded(_ data: Data) throws -> Workspace {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var value = try decoder.decode(Workspace.self, from: data)
        if (1...3).contains(value.version) { value.version = 4 }
        try value.validate(); return value
    }
}

public enum CalendarLogic {
    public static func occurrences(of record: WorkRecord, in interval: DateInterval, calendar input: Calendar = .current) -> [Date] {
        if record.repeatRule == .none { return interval.contains(record.startAt) ? [record.startAt] : [] }
        // Always Gregorian, matching recurrenceDate/recurrenceIndex, whatever the system calendar is.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? input.timeZone
        let component: Calendar.Component = record.repeatRule == .daily ? .day : record.repeatRule == .weekly ? .weekOfYear : .month
        let anchor = record.recurrenceAnchor ?? record.startAt
        // Jump close to the visible interval; do not enumerate years of daily events.
        let distance = calendar.dateComponents([component], from: anchor, to: max(interval.start, record.startAt)).value(for: component) ?? 0
        var index = max(0, distance - 1), result: [Date] = []
        var visited = 0
        while let date = calendar.date(byAdding: component, value: index, to: anchor), date <= interval.end {
            if let until = record.repeatUntil, date >= until { break }
            if date >= max(interval.start, record.startAt), !(record.excludedOccurrences ?? []).contains(date) { result.append(date) }
            index += 1
            visited += 1
            if visited >= 1002 { break }
        }
        return result
    }
    public static func deadlinePassed(_ record: WorkRecord, now: Date, calendar input: Calendar = .current) -> Bool {
        guard let due = record.dueAt, record.status == .active else { return false }
        var calendar = input; calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? input.timeZone
        let cutoff = record.dueDateOnly ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: due))! : due
        return now >= cutoff
    }
}
