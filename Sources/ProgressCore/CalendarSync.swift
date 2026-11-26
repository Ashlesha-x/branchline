import Foundation

public struct CalendarEventValue: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var timeZoneID: String
    public init(title: String, body: String, start: Date, end: Date, allDay: Bool, timeZoneID: String) {
        self.title = title; self.body = body; self.start = start; self.end = end; self.allDay = allDay; self.timeZoneID = timeZoneID
    }
    public init(_ record: WorkRecord) { self.init(title: record.title, body: record.body, start: record.startAt, end: record.endAt ?? record.startAt, allDay: record.dateOnly, timeZoneID: record.timeZoneID) }
    public func applying(to input: WorkRecord) -> WorkRecord {
        var r = input; r.title = title; r.body = body; r.startAt = start; r.endAt = end; r.dateOnly = allDay; r.timeZoneID = timeZoneID; return r
    }
}
public struct CalendarEventLink: Codable, Equatable, Sendable {
    public var key: String
    public var calendarTitle: String
    public var externalID: String
    public var occurrence: Date?
    public var calendarID: String?
    public var eventID: String?
    public var disposition: CalendarDisposition?
    public var sourceIssue: CalendarSourceIssue?
    public var statusBeforeCancellation: WorkStatus?
    public var lastImported: CalendarEventValue
}
public struct CalendarImportItem: Identifiable, Sendable {
    public var key: String
    public var calendarTitle: String
    public var externalID: String
    public var occurrence: Date?
    public var value: CalendarEventValue
    public var calendarID: String?
    public var eventID: String?
    public var isCancelled = false
    public var id: String { key }
    public init(key: String, calendarTitle: String, externalID: String, occurrence: Date?, value: CalendarEventValue, calendarID: String? = nil, eventID: String? = nil, isCancelled: Bool = false) {
        self.key = key; self.calendarTitle = calendarTitle; self.externalID = externalID; self.occurrence = occurrence; self.value = value; self.calendarID = calendarID; self.eventID = eventID; self.isCancelled = isCancelled
    }
}
public enum CalendarSyncState: String, Sendable { case new = "新会议", update = "日历有更新", unchanged = "已同步", conflict = "待处理冲突", sourceReview = "来源已取消，待确认", cancelled = "日历已取消" }
public struct CalendarSyncChange: Sendable {
    public var state: CalendarSyncState
    public var record: WorkRecord?
}
extension Workspace {
    public func calendarChange(_ item: CalendarImportItem, location: RecordingLocation?) -> CalendarSyncChange {
        if item.isCancelled { let link = records.first { $0.kind == .meeting && $0.calendarLink?.key == item.key && ($0.calendarLink?.calendarID == nil || item.calendarID == nil || $0.calendarLink?.calendarID == item.calendarID) }?.calendarLink; return CalendarSyncChange(state: link != nil && !(link?.sourceIssue == .cancelled && link?.disposition != nil) ? .sourceReview : .cancelled, record: nil) }
        guard let existing = records.first(where: { $0.calendarLink?.key == item.key }), let link = existing.calendarLink else {
            var created = item.value.applying(to: WorkRecord(kind: .meeting))
            if let location { created = location.applying(to: created) }
            created.calendarLink = CalendarEventLink(key: item.key, calendarTitle: item.calendarTitle, externalID: item.externalID, occurrence: item.occurrence, calendarID: item.calendarID, eventID: item.eventID, lastImported: item.value)
            return CalendarSyncChange(state: .new, record: created)
        }
        if let a = link.calendarID, let b = item.calendarID, a != b { return CalendarSyncChange(state: .conflict, record: nil) }
        if link.disposition == .cancelled && link.sourceIssue != nil { return CalendarSyncChange(state: .conflict, record: nil) }
        if existing.kind != .meeting { return CalendarSyncChange(state: .conflict, record: nil) }
        let current = CalendarEventValue(existing), base = link.lastImported, incoming = item.value
        if existing.repeatRule != .none { return CalendarSyncChange(state: .conflict, record: nil) }
        var merged = current
        var conflict = false
        func field<T: Equatable>(_ old: T, _ local: T, _ remote: T) -> T {
            if local == old || local == remote { return remote }
            if remote == old { return local }
            conflict = true; return local
        }
        func dateField(_ old: Date, _ local: Date, _ remote: Date) -> Date {
            let o = floor(old.timeIntervalSince1970), l = floor(local.timeIntervalSince1970), r = floor(remote.timeIntervalSince1970)
            if l == o || l == r { return remote }; if r == o { return local }; conflict = true; return local
        }
        merged.title = field(base.title, current.title, incoming.title)
        merged.body = field(base.body, current.body, incoming.body)
        merged.start = dateField(base.start, current.start, incoming.start)
        merged.end = dateField(base.end, current.end, incoming.end)
        merged.allDay = field(base.allDay, current.allDay, incoming.allDay)
        merged.timeZoneID = field(base.timeZoneID, current.timeZoneID, incoming.timeZoneID)
        if conflict { return CalendarSyncChange(state: .conflict, record: nil) }
        if !existing.reminderDates.isEmpty && (!CalendarField.start.equal(current, merged) || !CalendarField.end.equal(current, merged)) { return CalendarSyncChange(state: .conflict, record: nil) }
        var updated = merged.applying(to: existing)
        updated.calendarLink?.calendarTitle = item.calendarTitle
        updated.calendarLink?.calendarID = item.calendarID ?? link.calendarID; updated.calendarLink?.eventID = item.eventID ?? link.eventID
        updated.calendarLink?.lastImported = incoming
        if link.disposition != .cancelled { updated.calendarLink?.sourceIssue = nil; updated.calendarLink?.disposition = nil }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        let changed = (try? encoder.encode(updated)) != (try? encoder.encode(existing))
        return CalendarSyncChange(state: changed ? .update : .unchanged, record: updated)
    }
    public mutating func syncingCalendar(_ items: [CalendarImportItem], location: RecordingLocation?) throws -> (inserted: Int, updated: Int, conflicts: Int) {
        var inserted = 0, updated = 0, conflicts = 0
        for item in items {
            let change = calendarChange(item, location: location)
            if change.state == .sourceReview { continue }
            if change.state == .conflict { conflicts += 1; continue }
            if change.state == .unchanged { continue }
            guard let record = change.record else { continue }
            if change.state == .new { guard location?.exists(in: self) == true else { throw WorkspaceError("新会议需要选择有效归属。") }; inserted += 1 }
            else { updated += 1 }
            try putRecord(record)
        }
        try validate(); return (inserted, updated, conflicts)
    }
}

// MARK: - Writing back to Apple Calendar

extension CalendarEventValue {
    /// Lines the importer adds to the body from event fields other than notes.
    public static let importedFieldPrefixes = ["地点：", "链接："]
    /// The body without the lines the importer derived from location and URL, for writing into event notes.
    public var notesForCalendar: String {
        body.components(separatedBy: "\n").filter { line in !Self.importedFieldPrefixes.contains { line.hasPrefix($0) } }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension CalendarEventLink {
    public init(key: String, calendarTitle: String, externalID: String, occurrence: Date?, calendarID: String?, eventID: String?, lastImported: CalendarEventValue) {
        self.key = key; self.calendarTitle = calendarTitle; self.externalID = externalID; self.occurrence = occurrence
        self.calendarID = calendarID; self.eventID = eventID; self.lastImported = lastImported
    }
}

extension WorkRecord {
    /// Only plain (non-repeating) meetings can be written to Apple Calendar.
    public var canWriteToCalendar: Bool { kind == .meeting && repeatRule == .none && seriesID == nil }
}

extension Workspace {
    /// Linked meetings whose calendar fields changed in this write and now differ from the last synced value.
    public func calendarPushCandidates(since previous: Workspace) -> [WorkRecord] {
        records.filter { record in
            guard record.canWriteToCalendar, let link = record.calendarLink, link.disposition != .cancelled,
                  let before = previous.record(record.id), before != record else { return false }
            let now = CalendarEventValue(record)
            return CalendarField.allCases.contains { !$0.equal(now, link.lastImported) } &&
                CalendarField.allCases.contains { !$0.equal(now, CalendarEventValue(before)) }
        }
    }
    /// Linked meetings that existed in `previous` and are gone now (deleted or moved to trash).
    public func removedCalendarLinks(since previous: Workspace) -> [WorkRecord] {
        let remaining = Set(records.map(\.id))
        return previous.records.filter { $0.calendarLink != nil && $0.calendarLink?.disposition != .cancelled && !remaining.contains($0.id) }
    }
    /// Records the value just written to the calendar as the new sync baseline.
    public mutating func markCalendarWritten(_ id: UUID, value: CalendarEventValue, link: CalendarEventLink? = nil) throws {
        guard var record = record(id) else { throw WorkspaceError("会议已不存在。") }
        if let link { record.calendarLink = link } else { record.calendarLink?.lastImported = value }
        guard record.calendarLink != nil else { throw WorkspaceError("会议没有关联日历事件。") }
        try putRecord(record)
    }
}
