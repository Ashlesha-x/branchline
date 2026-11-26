import Foundation

public enum CalendarDisposition: String, Codable, Sendable { case keptHistory, cancelled }
public enum CalendarSourceIssue: String, Codable, Sendable { case missing, cancelled }
public enum CalendarField: String, CaseIterable, Identifiable, Sendable {
    case title = "标题", body = "正文", start = "开始", end = "结束", allDay = "全天", timeZone = "时区"
    public var id: String { rawValue }
    public func value(_ v: CalendarEventValue) -> String {
        switch self {
        case .title: v.title
        case .body: v.body
        case .start: WorkDateText.date(v.start, timed: !v.allDay, zone: v.timeZoneID)
        case .end: WorkDateText.date(v.end, timed: !v.allDay, zone: v.timeZoneID)
        case .allDay: v.allDay ? "是" : "否"
        case .timeZone: v.timeZoneID
        }
    }
    public func equal(_ a: CalendarEventValue, _ b: CalendarEventValue) -> Bool {
        switch self {
        case .title: a.title == b.title
        case .body: a.body == b.body
        case .start: floor(a.start.timeIntervalSince1970) == floor(b.start.timeIntervalSince1970)
        case .end: floor(a.end.timeIntervalSince1970) == floor(b.end.timeIntervalSince1970)
        case .allDay: a.allDay == b.allDay
        case .timeZone: a.timeZoneID == b.timeZoneID
        }
    }
    public func copying(from source: CalendarEventValue, into target: inout CalendarEventValue) {
        switch self {
        case .title: target.title = source.title
        case .body: target.body = source.body
        case .start: target.start = source.start
        case .end: target.end = source.end
        case .allDay: target.allDay = source.allDay
        case .timeZone: target.timeZoneID = source.timeZoneID
        }
    }
}
public enum CalendarSide: String, CaseIterable, Sendable { case local = "保留脉络", calendar = "采用日历" }
public enum CalendarReminderChoice: String, CaseIterable, Sendable { case keep = "保持原时间", shift = "随改期移动", remove = "移除固定提醒" }
public struct CalendarSourceReview: Identifiable, Sendable {
    public var record: WorkRecord
    public var issue: CalendarSourceIssue
    public var id: UUID { record.id }
    public init(record: WorkRecord, issue: CalendarSourceIssue) { self.record = record; self.issue = issue }
    public var alreadyHandled: Bool { record.calendarLink?.sourceIssue == issue && record.calendarLink?.disposition != nil }
}
extension Workspace {
    public func calendarConflictingFields(_ item: CalendarImportItem) -> [CalendarField] {
        guard let record = records.first(where: { $0.calendarLink?.key == item.key }), let baseline = record.calendarLink?.lastImported else { return [] }
        let local = CalendarEventValue(record)
        return CalendarField.allCases.filter { !$0.equal(local, baseline) && !$0.equal(item.value, baseline) && !$0.equal(local, item.value) }
    }
    public mutating func resolveCalendar(_ item: CalendarImportItem, expected: WorkRecord, choices: [CalendarField: CalendarSide], reminders: CalendarReminderChoice?, resume: Bool = false, rebind: Bool = false) throws {
        guard let current = record(expected.id), current == expected, current.calendarLink?.key == item.key,
              let baseline = current.calendarLink?.lastImported, !item.isCancelled else { throw WorkspaceError("会议或来源已变化，请重新读取后处理。") }
        guard current.kind == .meeting, current.repeatRule == .none else { throw WorkspaceError("请先将记录恢复为普通会议，再处理日历冲突。") }
        if let a = current.calendarLink?.calendarID, let b = item.calendarID, a != b, !rebind { throw WorkspaceError("来源日历不同，请明确确认是否重新关联。") }
        let local = CalendarEventValue(current)
        let conflicting = calendarConflictingFields(item)
        guard conflicting.allSatisfy({ choices[$0] != nil }) else { throw WorkspaceError("请为每个冲突字段选择保留哪一边。") }
        var merged = local
        for field in CalendarField.allCases {
            let side = choices[field] ?? (field.equal(local, baseline) ? .calendar : .local)
            field.copying(from: side == .calendar ? item.value : local, into: &merged)
        }
        var result = merged.applying(to: current)
        let moved = !CalendarField.start.equal(local, merged) || !CalendarField.end.equal(local, merged)
        if moved && !current.reminderDates.isEmpty {
            guard let reminders else { throw WorkspaceError("请确认固定提醒如何处理。") }
            switch reminders {
            case .keep: break
            case .shift: result.reminderDates = current.reminderDates.map { $0.addingTimeInterval(merged.start.timeIntervalSince(current.startAt)) }
            case .remove: result.reminderDates = []
            }
        }
        result.calendarLink?.lastImported = item.value
        result.calendarLink?.calendarTitle = item.calendarTitle
        result.calendarLink?.calendarID = item.calendarID ?? current.calendarLink?.calendarID
        result.calendarLink?.eventID = item.eventID ?? current.calendarLink?.eventID
        result.calendarLink?.sourceIssue = nil
        if resume && current.calendarLink?.disposition == .cancelled {
            result.status = current.calendarLink?.statusBeforeCancellation ?? .active
            result.calendarLink?.disposition = nil; result.calendarLink?.statusBeforeCancellation = nil
        } else if current.calendarLink?.disposition != .cancelled { result.calendarLink?.disposition = nil }
        var next = self; try next.putRecord(result)
        next.history.append(ChangeRecord(entityID: result.id, summary: "逐项处理日历差异并更新同步基准。"))
        try next.validate(); self = next
    }
    public mutating func handleCalendarSource(_ review: CalendarSourceReview, decision: CalendarDisposition, restore: Bool = false) throws {
        guard var value = record(review.id), value == review.record, value.calendarLink != nil, value.kind == .meeting else { throw WorkspaceError("会议已变化，请重新复核来源。") }
        if decision == .cancelled {
            if value.calendarLink?.disposition != .cancelled { value.calendarLink?.statusBeforeCancellation = value.status }
            if value.status == .active { value.status = .paused }
        } else if value.calendarLink?.disposition == .cancelled {
            if restore { value.status = value.calendarLink?.statusBeforeCancellation ?? .active; value.calendarLink?.statusBeforeCancellation = nil }
            else if value.status == .active { value.status = .paused }
        }
        value.calendarLink?.disposition = decision; value.calendarLink?.sourceIssue = review.issue
        var next = self; try next.putRecord(value)
        next.history.append(ChangeRecord(entityID: value.id, summary: restore ? "恢复本地会议与后续提醒。" : decision == .cancelled ? "复核日历来源后标记取消，停止后续提醒。" : "复核日历来源后保留记录。"))
        try next.validate(); self = next
    }
}
