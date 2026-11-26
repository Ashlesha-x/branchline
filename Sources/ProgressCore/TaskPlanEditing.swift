import Foundation

extension Workspace {
    public func taskFamilyID(for record: WorkRecord) -> UUID? {
        guard let id = record.taskSeriesID else { return nil }
        return taskPlans?.first { $0.id == id }?.familyID ?? id
    }
    public func editingTaskPlan(_ input: WorkRecord, scope: RecurrenceScope, now: Date = Date()) throws -> Workspace {
        guard let old = record(input.id), let series = old.taskSeriesID, let boundary = old.taskOccurrence,
              let index = taskPlans?.firstIndex(where: { $0.id == series }), let plan = taskPlans?[index], input.kind == .task,
              scope != .series else { throw WorkspaceError("重复任务或修改范围无效。") }
        var next = self
        if scope == .occurrence {
            var value = input; value.taskSeriesID = series; value.taskOccurrence = boundary; value.taskRepeatRule = plan.rule; value.taskRepeatUntil = plan.until
            try next.putRecord(value, now: now); return next
        }
        guard plan.active else { throw WorkspaceError("该重复计划已停止，请选择仍在推进的计划。") }
        let rule = input.taskRepeatRule ?? plan.rule
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: input.timeZoneID) ?? .current
        let dateChanged = input.dueAt != old.dueAt || input.hasPlannedStart != old.hasPlannedStart || (input.hasPlannedStart && input.startAt != old.startAt)
        let anchor: Date? = rule == .none ? boundary : dateChanged ? input.dueAt ?? (input.hasPlannedStart ? input.startAt : nil) : boundary
        guard let anchor else { throw WorkspaceError("后续重复计划需要开始或截止日期。") }
        func shifted(_ date: Date, from: Date, to: Date) -> Date {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day!
            func clock(_ d: Date) -> Int { let c = calendar.dateComponents([.hour, .minute, .second], from: d); return c.hour! * 3600 + c.minute! * 60 + c.second! }
            return calendar.date(byAdding: .second, value: clock(to) - clock(from), to: calendar.date(byAdding: .day, value: days, to: date)!)!
        }
        func patchedScalars(_ original: WorkRecord) -> WorkRecord {
            var value = original
            func patch<T: Equatable>(_ key: WritableKeyPath<WorkRecord, T>) { if input[keyPath: key] != old[keyPath: key] { value[keyPath: key] = input[keyPath: key] } }
            patch(\.title); patch(\.body); patch(\.materials); patch(\.projectIDs); patch(\.branchID); patch(\.dependencies)
            patch(\.dateOnly); patch(\.dueDateOnly); patch(\.timeZoneID); patch(\.taskScheduled); patch(\.relativeReminders)
            value.updatedAt = now; return value
        }
        var template = patchedScalars(plan.prototype)
        let startChanged = input.startAt != old.startAt || input.hasPlannedStart != old.hasPlannedStart
        template.startAt = startChanged ? input.startAt : shifted(plan.prototype.startAt, from: plan.anchor, to: boundary)
        template.endAt = input.endAt != old.endAt ? input.endAt : plan.prototype.endAt.map { shifted($0, from: plan.anchor, to: boundary) }
        template.dueAt = input.dueAt != old.dueAt ? input.dueAt : plan.prototype.dueAt.map { shifted($0, from: plan.anchor, to: boundary) }
        template.reminderDates = input.reminderDates != old.reminderDates ? input.reminderDates : plan.prototype.reminderDates.map { shifted($0, from: plan.anchor, to: boundary) }
        func changedFields(_ original: WorkRecord, at occurrence: Date) -> WorkRecord {
            var value = patchedScalars(original)
            let oldOccurrence = original.taskOccurrence ?? plan.anchor
            func date(_ actual: Date?, oldTemplate: Date?, newTemplate: Date?, changed: Bool) -> Date? {
                guard let newTemplate else { return nil }
                let target = shifted(newTemplate, from: anchor, to: occurrence)
                guard !changed, let actual, let oldTemplate else { return target }
                return shifted(actual, from: shifted(oldTemplate, from: plan.anchor, to: oldOccurrence), to: target)
            }
            if value.hasPlannedStart { value.startAt = date(original.startAt, oldTemplate: plan.prototype.startAt, newTemplate: template.startAt, changed: startChanged)! }
            value.endAt = date(original.endAt, oldTemplate: plan.prototype.endAt, newTemplate: template.endAt, changed: input.endAt != old.endAt)
            value.dueAt = date(original.dueAt, oldTemplate: plan.prototype.dueAt, newTemplate: template.dueAt, changed: input.dueAt != old.dueAt)
            if input.reminderDates != old.reminderDates { value.reminderDates = template.reminderDates.map { shifted($0, from: anchor, to: occurrence) } }
            else {
                let oldReference = plan.prototype.reminderDates.first.map { shifted($0, from: plan.anchor, to: oldOccurrence) } ?? oldOccurrence
                let newReference = template.reminderDates.first.map { shifted($0, from: anchor, to: occurrence) } ?? occurrence
                value.reminderDates = original.reminderDates.map { shifted($0, from: oldReference, to: newReference) }
            }
            return value
        }
        next.taskPlans![index].active = false
        let pending = records.filter { $0.taskSeriesID == series && ($0.taskOccurrence ?? .distantPast) >= boundary }
        if rule == .none {
            for item in pending where item.status != .completed && item.status != .archived {
                let i = next.records.firstIndex { $0.id == item.id }!
                if item.id == input.id { var value = input; value.taskSeriesID = nil; value.taskOccurrence = nil; value.taskRepeatRule = nil; value.taskRepeatUntil = nil; next.records[i] = value }
                else { next.records[i].status = .archived; next.records[i].updatedAt = now }
            }
        } else {
            var prototype = template
            prototype.status = .active; prototype.completedAt = nil; prototype.taskSeriesID = nil; prototype.taskOccurrence = nil; prototype.taskRepeatRule = nil; prototype.taskRepeatUntil = nil
            var replacement = TaskPlan(prototype: prototype, rule: rule, anchor: anchor, until: input.taskRepeatUntil)
            replacement.familyID = plan.familyID ?? plan.id
            func cursor(_ plan: TaskPlan) -> WorkRecord { var r = plan.prototype; r.kind = .meeting; r.startAt = plan.anchor; r.repeatRule = plan.rule; r.recurrenceAnchor = plan.anchor; r.repeatUntil = nil; r.excludedOccurrences = nil; return r }
            let oldCursor = cursor(plan), newCursor = cursor(replacement)
            guard let firstIndex = CalendarLogic.recurrenceIndex(oldCursor, date: boundary) else { throw WorkspaceError("无法定位本次任务在重复计划中的位置。") }
            func mapped(_ date: Date) -> Date? {
                guard let index = CalendarLogic.recurrenceIndex(oldCursor, date: date), index >= firstIndex else { return nil }
                return CalendarLogic.recurrenceDate(newCursor, index: index - firstIndex)
            }
            func retainedSlot(_ date: Date) -> Date? {
                if rule == plan.rule { return mapped(date) }
                let component: Calendar.Component = rule == .daily ? .day : rule == .weekly ? .weekOfYear : .month
                let distance = calendar.dateComponents([component], from: anchor, to: date).value(for: component) ?? 0
                return (max(0, distance - 2)...max(0, distance + 2)).compactMap { CalendarLogic.recurrenceDate(newCursor, index: $0) }.first { calendar.isDate($0, inSameDayAs: date) }
            }
            replacement.excluded = plan.excluded.filter { $0 >= boundary }.compactMap(retainedSlot)
            for item in pending {
                let i = next.records.firstIndex { $0.id == item.id }!
                guard let date = item.taskOccurrence.flatMap(mapped) else { throw WorkspaceError("无法映射后续任务日期，当前计划未修改。") }
                if item.status == .completed || item.status == .archived {
                    if item.id == input.id { replacement.excluded.append(anchor) }
                    else if let retained = item.taskOccurrence.flatMap(retainedSlot) { replacement.excluded.append(retained) }
                    continue
                }
                if let until = replacement.until, date >= until { next.records[i].status = .archived; next.records[i].updatedAt = now; continue }
                var value = changedFields(item, at: date)
                if item.id == input.id { value = input }
                value.taskSeriesID = replacement.id; value.taskOccurrence = date; value.taskRepeatRule = rule; value.taskRepeatUntil = replacement.until; value.updatedAt = now
                next.records[i] = value
            }
            replacement.excluded = Array(Set(replacement.excluded)).sorted()
            next.taskPlans!.append(replacement)
            _ = try next.materializeTaskPlans(now: now)
        }
        next.history.append(ChangeRecord(entityID: input.id, summary: "调整重复任务：本次及以后；已完成内容保持原样。"))
        try next.validate(); return next
    }
}
