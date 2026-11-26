import Foundation

public enum RelativeReminder: String, Codable, CaseIterable, Sendable {
    case start15Minutes, start1Hour, duePreviousDay9
    public var title: String {
        switch self { case .start15Minutes: "开始前 15 分钟"; case .start1Hour: "开始前 1 小时"; case .duePreviousDay9: "截止前一天 09:00" }
    }
    public func date(for record: WorkRecord, occurrence: Date? = nil) -> Date? {
        switch self {
        case .start15Minutes: return (occurrence ?? record.startAt).addingTimeInterval(-900)
        case .start1Hour: return (occurrence ?? record.startAt).addingTimeInterval(-3600)
        case .duePreviousDay9:
            guard let due = record.dueAt else { return nil }
            var calendar = Calendar.current; calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
            guard let previous = calendar.date(byAdding: .day, value: -1, to: due) else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: previous)
        }
    }
}

extension WorkRecord {
    // Missing fields in old backups preserve the previously displayed schedule.
    public var hasPlannedStart: Bool { taskScheduled ?? true }
    public var relativeRules: [RelativeReminder] { relativeReminders ?? [] }
    public var hasReminders: Bool { !reminderDates.isEmpty || !relativeRules.isEmpty }
    public var availableReminderRules: [RelativeReminder] {
        (kind != .task || hasPlannedStart ? [.start15Minutes, .start1Hour] : []) + (dueAt == nil ? [] : [.duePreviousDay9])
    }
    /// Fixed legacy reminders remain fixed for single records. Repeated meetings
    /// retain their legacy recurrence anchor; new relative rules use event occurrences.
    public func reminderOccurrences(in interval: DateInterval) -> [Date] {
        Array(Set(reminderSchedule(in: interval).map(\.date))).sorted()
    }
    /// Noon on the calendar day `date` falls on in `timeZoneID`; date-only values anchored here
    /// keep their day under any UTC offset within ±11 hours.
    public static func dateOnlyAnchor(_ date: Date, timeZoneID: String) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: calendar.startOfDay(for: date)) ?? date
    }
    public func rescheduleDelta(from old: WorkRecord) -> TimeInterval? {
        if kind == .task, dueAt != old.dueAt, let dueAt, let previous = old.dueAt { return dueAt.timeIntervalSince(previous) }
        if startAt != old.startAt { return startAt.timeIntervalSince(old.startAt) }
        return nil
    }
}

public enum SearchEntity: String, CaseIterable, Codable, Sendable {
    case project, branch, record, merge
    public var title: String { switch self { case .project: "项目"; case .branch: "分支"; case .record: "记录"; case .merge: "成果" } }
}
public struct SearchHit: Identifiable, Sendable {
    public var id: UUID
    public var kind: SearchEntity
    public var title: String
    public var detail: String
    public var date: Date
}
extension Workspace {
    public func search(_ text: String, projectID: UUID? = nil, includeAll: Bool = false) -> [SearchHit] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || includeAll else { return [] }
        func matches(_ fields: String...) -> Bool { query.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(query) } }
        var hits: [SearchHit] = []
        for p in projects where (projectID == nil || p.id == projectID) && matches(p.title, p.note) {
            hits.append(SearchHit(id: p.id, kind: .project, title: p.title, detail: p.note, date: p.createdAt))
        }
        for b in branches where (projectID == nil || b.projectIDs.contains(projectID!)) && matches(b.title, b.note) {
            hits.append(SearchHit(id: b.id, kind: .branch, title: b.title, detail: b.note, date: b.startAt))
        }
        for r in records where (projectID == nil || self.projects(for: r).contains(projectID!)) && matches(r.title, r.body) {
            hits.append(SearchHit(id: r.id, kind: .record, title: r.title, detail: r.body, date: r.kind == .task && !r.hasPlannedStart ? r.dueAt ?? r.createdAt : r.startAt))
        }
        for m in merges where (projectID == nil || m.projectID == projectID || branch(m.targetBranchID)?.projectIDs.contains(projectID!) == true) && matches(m.summary) {
            hits.append(SearchHit(id: m.id, kind: .merge, title: m.summary, detail: "\(branch(m.branchID)?.title ?? "分支") → \(mergeTargetTitle(m))", date: m.date))
        }
        return hits.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }
    public func lockedProjectIDs(for branchID: UUID) -> Set<UUID> { Set(merges.filter { $0.branchID == branchID }.compactMap(\.projectID)) }
}

public enum AgendaScope: String, CaseIterable, Sendable {
    case today = "今天", overdue = "逾期", week = "未来七天", blocked = "等待依赖", unscheduled = "未安排日期"
}
public enum AgendaReason: String, Sendable {
    case dueToday = "今天截止", plannedToday = "计划覆盖今天"
}
public struct AgendaItem: Identifiable, Sendable {
    public var record: WorkRecord
    public var date: Date
    public var end: Date?
    public var reasons: [AgendaReason] = []
    public var id: String { "\(record.id)-\(date.timeIntervalSince1970)" }
}
extension Workspace {
    /// Start of the same year-month-day in `calendar` as `date` has in `timeZoneID`.
    static func sameCalendarDay(_ date: Date, from timeZoneID: String, in calendar: Calendar) -> Date {
        var source = Calendar(identifier: .gregorian); source.timeZone = TimeZone(identifier: timeZoneID) ?? calendar.timeZone
        let parts = source.dateComponents([.year, .month, .day], from: date)
        var target = Calendar(identifier: .gregorian); target.timeZone = calendar.timeZone
        return target.date(from: parts).map { calendar.startOfDay(for: $0) } ?? date
    }
    public func agenda(_ scope: AgendaScope, now: Date, calendar: Calendar = .current) -> [AgendaItem] {
        let day = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: scope == .week ? 7 : 1, to: day)!
        var result: [AgendaItem] = []
        for record in records where record.status == .active && record.kind != .progress {
            if record.kind == .meeting {
                guard scope == .today || scope == .week else { continue }
                let duration = max(0, (record.endAt ?? record.startAt).timeIntervalSince(record.startAt))
                let window = DateInterval(start: day.addingTimeInterval(-duration), end: end)
                for date in CalendarLogic.occurrences(of: record, in: window) where date < end && (date >= day || date.addingTimeInterval(duration) > day) {
                    result.append(AgendaItem(record: record, date: date, end: date.addingTimeInterval(duration)))
                }
                continue
            }
            let undated = !record.hasPlannedStart && record.endAt == nil && record.dueAt == nil
            var include = false
            var reasons: [AgendaReason] = []
            switch scope {
            case .overdue: include = CalendarLogic.deadlinePassed(record, now: now)
            case .blocked: include = !blockedBy(record).isEmpty
            case .unscheduled: include = undated
            case .today, .week:
                let dueInRange = record.dueAt.map { due in
                    // Date-only deadlines are a day in the record's time zone, as in deadlinePassed.
                    let instant = record.dueDateOnly ? Self.sameCalendarDay(due, from: record.timeZoneID, in: calendar) : due
                    return instant >= day && instant < end
                } ?? false
                let planEnd = record.endAt ?? record.dueAt ?? end
                let plannedInRange = record.hasPlannedStart && record.startAt < end && planEnd >= day
                include = dueInRange || plannedInRange
                if scope == .today {
                    if dueInRange { reasons.append(.dueToday) }
                    if plannedInRange { reasons.append(.plannedToday) }
                }
            }
            if include { result.append(AgendaItem(record: record, date: record.dueAt ?? record.startAt, end: record.endAt, reasons: reasons)) }
        }
        return result.sorted { $0.date == $1.date ? $0.record.id.uuidString < $1.record.id.uuidString : $0.date < $1.date }
    }
}

public enum WorkDateText {
    public static func date(_ date: Date, timed: Bool = false, zone: String = TimeZone.current.identifier) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: zone) ?? .current
        formatter.dateFormat = timed ? "yyyy年M月d日 HH:mm" : "yyyy年M月d日"
        return formatter.string(from: date)
    }
    /// Display form used across the app: "11月24日 周二 14:00"; the year appears only when it is not the current one.
    public static func short(_ date: Date, timed: Bool = false, zone: String = TimeZone.current.identifier, now: Date = Date(), weekday: Bool = true) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: zone) ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = formatter.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = (sameYear ? "M月d日" : "yyyy年M月d日") + (weekday ? " EEE" : "") + (timed ? " HH:mm" : "")
        return formatter.string(from: date)
    }
    public static func meetingShort(_ record: WorkRecord, occurrence: Date? = nil, now: Date = Date()) -> String {
        let start = occurrence ?? record.startAt
        guard let endAt = record.endAt else { return short(start, timed: true, zone: record.timeZoneID, now: now) }
        let end = start.addingTimeInterval(endAt.timeIntervalSince(record.startAt))
        var cal = Calendar.current; cal.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = cal.timeZone; formatter.dateFormat = "HH:mm"
        let endText = cal.isDate(start, inSameDayAs: end) ? formatter.string(from: end) : short(end, timed: true, zone: record.timeZoneID, now: now)
        return short(start, timed: true, zone: record.timeZoneID, now: now) + "–" + endText
    }
    public static func meeting(_ record: WorkRecord, occurrence: Date? = nil) -> String {
        let start = occurrence ?? record.startAt
        guard let endAt = record.endAt else { return date(start, timed: true, zone: record.timeZoneID) }
        let end = start.addingTimeInterval(endAt.timeIntervalSince(record.startAt))
        var cal = Calendar.current; cal.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = cal.timeZone; formatter.dateFormat = "HH:mm"
        let endText = cal.isDate(start, inSameDayAs: end) ? formatter.string(from: end) : date(end, timed: true, zone: record.timeZoneID)
        return date(start, timed: true, zone: record.timeZoneID) + "–" + endText
    }
}
