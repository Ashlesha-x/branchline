import Foundation

public struct TaskPlan: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var familyID: UUID?
    public var prototype: WorkRecord
    public var rule: RepeatRule
    public var anchor: Date
    public var until: Date?
    public var expandedThrough: Date?
    public var active = true
    public var excluded: [Date] = []
    public init(prototype: WorkRecord, rule: RepeatRule, anchor: Date, until: Date?) {
        self.prototype = prototype; self.rule = rule; self.anchor = anchor; self.until = until
    }
}

extension Workspace {
    public mutating func createTaskPlan(from input: WorkRecord, now: Date = Date()) throws {
        guard input.kind == .task, input.status == .active, let rule = input.taskRepeatRule, rule != .none,
              let anchor = input.dueAt ?? (input.hasPlannedStart ? input.startAt : nil) else { throw WorkspaceError("重复任务需要开始或截止日期，初始状态为进行中。") }
        guard record(input.id) == nil else { throw WorkspaceError("请新建重复计划，已有任务继续保留独立状态。") }
        var prototype = input; prototype.taskSeriesID = nil; prototype.taskOccurrence = nil; prototype.taskRepeatRule = nil; prototype.taskRepeatUntil = nil
        let plan = TaskPlan(prototype: prototype, rule: rule, anchor: anchor, until: input.taskRepeatUntil)
        taskPlans = (taskPlans ?? []) + [plan]
        try validateTaskPlans()
        _ = try materializeTaskPlans(now: now)
        history.append(ChangeRecord(entityID: plan.id, summary: "创建重复任务计划：\(rule.title) · \(input.title)"))
    }
    @discardableResult public mutating func materializeTaskPlans(now: Date = Date()) throws -> Bool {
        guard var plans = taskPlans else { return false }
        var changed = false
        for index in plans.indices where plans[index].active {
            var plan = plans[index]
            if plan.prototype.recordingLocation?.isArchived(in: self) == true { continue }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: plan.prototype.timeZoneID) ?? .current
            let horizon = max(calendar.date(byAdding: .day, value: plan.rule == .monthly ? 61 : 31, to: calendar.startOfDay(for: now))!, plan.anchor.addingTimeInterval(1))
            let limit = min(horizon, plan.until ?? horizon)
            let start = plan.expandedThrough ?? plan.anchor
            guard start < limit else { continue }
            var recurrence = plan.prototype; recurrence.kind = .meeting; recurrence.repeatRule = plan.rule; recurrence.startAt = plan.anchor; recurrence.recurrenceAnchor = plan.anchor; recurrence.repeatUntil = plan.until; recurrence.excludedOccurrences = nil
            let dates = Array(CalendarLogic.occurrences(of: recurrence, in: DateInterval(start: start, end: limit), calendar: calendar).filter { $0 < limit }.prefix(200))
            let existing = Set(records.filter { $0.taskSeriesID == plan.id }.compactMap { $0.taskOccurrence }.map { floor($0.timeIntervalSince1970) })
            let excluded = Set(plan.excluded.map { floor($0.timeIntervalSince1970) })
            for date in dates where !existing.contains(floor(date.timeIntervalSince1970)) && !excluded.contains(floor(date.timeIntervalSince1970)) {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: plan.anchor), to: calendar.startOfDay(for: date)).day!
                func shifted(_ original: Date) -> Date { calendar.date(byAdding: .day, value: days, to: original)! }
                var item = plan.prototype
                item.id = date == plan.anchor && !records.contains(where: { $0.id == item.id }) ? item.id : UUID()
                if item.hasPlannedStart { item.startAt = shifted(item.startAt) }
                item.endAt = item.endAt.map(shifted); item.dueAt = item.dueAt.map(shifted)
                item.reminderDates = item.reminderDates.map(shifted)
                item.status = .active; item.completedAt = nil; item.createdAt = now; item.updatedAt = now
                item.taskSeriesID = plan.id; item.taskOccurrence = date; item.taskRepeatRule = plan.rule; item.taskRepeatUntil = plan.until
                records.append(item)
            }
            plan.expandedThrough = dates.count == 200 ? dates.last!.addingTimeInterval(1) : limit
            plans[index] = plan; changed = true
        }
        if changed { taskPlans = plans; try validate() }
        return changed
    }
    public mutating func stopTaskPlan(_ id: UUID, now: Date = Date()) throws {
        guard let index = taskPlans?.firstIndex(where: { $0.id == id }) else { throw WorkspaceError("重复计划不存在。") }
        taskPlans![index].active = false
        for i in records.indices where records[i].taskSeriesID == id && (records[i].taskOccurrence ?? .distantPast) > now && records[i].status == .active {
            records[i].status = .archived; records[i].updatedAt = now
        }
        history.append(ChangeRecord(entityID: id, summary: "停止后续重复任务；未来未完成安排已归档。"))
    }
    public func validateTaskPlans() throws {
        for plan in taskPlans ?? [] {
            let item = plan.prototype
            try item.validateMaterials()
            guard plan.rule != .none, item.kind == .task, !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.recordingLocation?.exists(in: self) == true, TimeZone(identifier: item.timeZoneID) != nil,
                  plan.until.map({ $0 > plan.anchor }) ?? true,
                  item.dueAt != nil || item.hasPlannedStart,
                  Set(item.dependencies).isSubset(of: Set(records.filter { $0.kind == .task }.map(\.id))) else { throw WorkspaceError("重复任务计划的日期、归属或依赖无效。") }
        }
        let keys = records.compactMap { item in item.taskSeriesID.flatMap { series in item.taskOccurrence.map { "\(series)-\(floor($0.timeIntervalSince1970))" } } }
        guard Set(keys).count == keys.count else { throw WorkspaceError("同一次重复任务被重复生成。") }
    }
}
