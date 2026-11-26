import Foundation

public enum RecurrenceScope: String, CaseIterable, Codable, Sendable {
    case occurrence = "仅本次", following = "本次及以后", series = "整个系列"
}
extension CalendarLogic {
    public static func recurrenceDate(_ record: WorkRecord, index: Int) -> Date? {
        guard index >= 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
        let component: Calendar.Component = record.repeatRule == .daily ? .day : record.repeatRule == .weekly ? .weekOfYear : .month
        return calendar.date(byAdding: component, value: index, to: record.recurrenceAnchor ?? record.startAt)
    }
    public static func recurrenceIndex(_ record: WorkRecord, date: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
        let component: Calendar.Component = record.repeatRule == .daily ? .day : record.repeatRule == .weekly ? .weekOfYear : .month
        let distance = calendar.dateComponents([component], from: record.recurrenceAnchor ?? record.startAt, to: date).value(for: component) ?? 0
        return (max(0, distance - 2)...max(0, distance + 2)).first { recurrenceDate(record, index: $0) == date }
    }
}
extension WorkRecord {
    public func occurrenceDraft(at date: Date) -> WorkRecord {
        var value = self
        let delta = date.timeIntervalSince(startAt)
        value.startAt = date; value.endAt = endAt?.addingTimeInterval(delta)
        value.reminderDates = reminderDates.map { $0.addingTimeInterval(delta) }
        return value
    }
}
extension Workspace {
    public func editingRecurring(_ id: UUID, occurrence: Date, input: WorkRecord, scope: RecurrenceScope) throws -> Workspace {
        guard let old = record(id), old.repeatRule != .none, old.kind == .meeting,
              input.kind == .meeting else { throw WorkspaceError("重复会议需要保留会议类型。") }
        var next = self
        let i = records.firstIndex { $0.id == id }!
        var edited = input; edited.updatedAt = Date()
        if scope != .series {
            guard CalendarLogic.occurrences(of: old, in: DateInterval(start: occurrence, duration: 0.001)).contains(occurrence) else { throw WorkspaceError("该次会议已改变或不再属于系列，请重新选择。") }
        }
        if scope == .occurrence {
            next.records[i].excludedOccurrences = Array(Set((old.excludedOccurrences ?? []) + [occurrence])).sorted()
            next.records[i].updatedAt = edited.updatedAt
            edited.id = UUID(); edited.repeatRule = .none; edited.repeatUntil = nil; edited.recurrenceAnchor = nil; edited.excludedOccurrences = nil
            edited.seriesID = id; edited.originalOccurrence = occurrence
            next.records.append(edited)
        } else {
            if scope == .following {
                next.records[i].repeatUntil = min(old.repeatUntil ?? occurrence, occurrence)
                next.records[i].excludedOccurrences = (old.excludedOccurrences ?? []).filter { $0 < occurrence }
                next.records[i].updatedAt = edited.updatedAt
                edited.id = UUID(); edited.createdAt = Date()
            }
            let boundary = scope == .following ? occurrence : old.startAt
            let firstIndex = CalendarLogic.recurrenceIndex(old, date: boundary) ?? 0
            if edited.startAt == boundary && edited.repeatRule == old.repeatRule && edited.timeZoneID == old.timeZoneID {
                edited.recurrenceAnchor = old.recurrenceAnchor ?? old.startAt
            } else { edited.recurrenceAnchor = nil }
            edited.repeatUntil = edited.repeatRule == .none ? nil : old.repeatUntil
            edited.seriesID = nil; edited.originalOccurrence = nil
            let newFirstIndex = CalendarLogic.recurrenceIndex(edited, date: edited.startAt) ?? 0
            var mapped: [Date: Date] = [:]
            if edited.repeatRule != .none {
                for date in old.excludedOccurrences ?? [] where date >= boundary {
                    guard let index = CalendarLogic.recurrenceIndex(old, date: date),
                          let replacement = CalendarLogic.recurrenceDate(edited, index: newFirstIndex + index - firstIndex) else { throw WorkspaceError("无法映射会议例外，请先检查该系列日期。") }
                    mapped[date] = replacement
                }
            }
            edited.excludedOccurrences = edited.repeatRule == .none ? nil : mapped.values.sorted()
            for j in next.records.indices where next.records[j].seriesID == id && (next.records[j].originalOccurrence ?? .distantPast) >= boundary {
                if let anchor = next.records[j].originalOccurrence, let replacement = mapped[anchor] {
                    next.records[j].seriesID = edited.id; next.records[j].originalOccurrence = replacement
                } else { next.records[j].seriesID = nil; next.records[j].originalOccurrence = nil }
            }
            if scope == .following { next.records.append(edited) } else { next.records[i] = edited }
        }
        next.history.append(ChangeRecord(entityID: edited.id, summary: "修改重复会议：\(scope.rawValue)。单次例外保留其自定义时间。"))
        try next.validate()
        return next
    }
    public func deletingRecurring(_ id: UUID, occurrence: Date, scope: RecurrenceScope) throws -> Workspace {
        guard let old = record(id), old.repeatRule != .none else { throw WorkspaceError("重复会议不存在。") }
        if scope == .series { return try deleting(.record(id)) }
        guard CalendarLogic.occurrences(of: old, in: DateInterval(start: occurrence, duration: 0.001)).contains(occurrence) else { throw WorkspaceError("该次会议已改变或不存在。") }
        var next = self
        let i = records.firstIndex { $0.id == id }!
        if scope == .occurrence {
            next.records[i].excludedOccurrences = Array(Set((old.excludedOccurrences ?? []) + [occurrence])).sorted()
        } else {
            for child in records where child.seriesID == id && (child.originalOccurrence ?? .distantPast) >= occurrence {
                next = try next.deleting(.record(child.id))
            }
            let parentIndex = next.records.firstIndex { $0.id == id }!
            next.records[parentIndex].repeatUntil = min(old.repeatUntil ?? occurrence, occurrence)
            next.records[parentIndex].excludedOccurrences = (old.excludedOccurrences ?? []).filter { $0 < occurrence }
        }
        next.records[next.records.firstIndex { $0.id == id }!].updatedAt = Date()
        try next.validate()
        return next
    }
}
