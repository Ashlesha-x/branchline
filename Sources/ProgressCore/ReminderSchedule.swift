import Foundation

public struct ReminderOccurrence: Hashable, Sendable, Identifiable {
    public let date: Date
    public let occurrence: Date?
    public var id: Self { self }
}

public struct QueuedReminder: Sendable, Identifiable {
    public let record: WorkRecord
    public let reminder: ReminderOccurrence
    public var fireDate: Date { Date(timeIntervalSince1970: floor(reminder.date.timeIntervalSince1970)) }
    public var id: String {
        let occurrence = reminder.occurrence.map { String(Int(floor($0.timeIntervalSince1970))) } ?? "single"
        return "branchline.v2.\(record.id).\(Int(fireDate.timeIntervalSince1970)).\(occurrence)"
    }
    public var target: ReminderNotificationTarget {
        ReminderNotificationTarget(recordID: record.id, occurrence: reminder.occurrence)
    }
}

extension Workspace {
    public func reminderQueue(now: Date, capacity: Int = 64, calendar: Calendar = .current) -> (scheduled: [QueuedReminder], hasMore: Bool) {
        let horizon = calendar.date(byAdding: .year, value: 1, to: now)!
        let window = DateInterval(start: now, end: horizon)
        var seen = Set<String>()
        var candidates: [QueuedReminder] = []
        for record in records where record.status == .active && record.hasReminders {
            for reminder in record.reminderSchedule(in: window) {
                let item = QueuedReminder(record: record, reminder: reminder)
                if item.fireDate > now && seen.insert(item.id).inserted { candidates.append(item) }
            }
        }
        candidates.sort {
            $0.fireDate == $1.fireDate ? $0.id < $1.id : $0.fireDate < $1.fireDate
        }
        let limit = max(0, capacity)
        return (Array(candidates.prefix(limit)), candidates.count > limit)
    }
}

extension WorkRecord {
    /// Keep the legacy reminder calendar anchor, but retain its corresponding event.
    private func fixedReminderProxy(_ date: Date) -> WorkRecord {
        var proxy = self
        proxy.startAt = date; proxy.recurrenceAnchor = nil
        proxy.repeatUntil = nil; proxy.excludedOccurrences = nil
        return proxy
    }
    private func allowsReminder(for occurrence: Date) -> Bool {
        occurrence >= startAt && (repeatUntil.map { occurrence < $0 } ?? true) && !(excludedOccurrences ?? []).contains(occurrence)
    }
    private func sortedReminders(_ reminders: [ReminderOccurrence]) -> [ReminderOccurrence] {
        Array(Set(reminders)).sorted {
            $0.date == $1.date ? ($0.occurrence ?? .distantPast) < ($1.occurrence ?? .distantPast) : $0.date < $1.date
        }
    }
    public func reminderSchedule(in interval: DateInterval) -> [ReminderOccurrence] {
        guard calendarLink?.disposition != .cancelled else { return [] }
        if repeatRule == .none {
            return reminderSchedule(for: startAt).filter { $0.date >= interval.start && $0.date < interval.end }
        }
        var result: [ReminderOccurrence] = []
        let offset = CalendarLogic.recurrenceIndex(self, date: startAt) ?? 0
        for anchor in reminderDates {
            let proxy = fixedReminderProxy(anchor)
            for date in CalendarLogic.occurrences(of: proxy, in: interval) where date < interval.end {
                guard let index = CalendarLogic.recurrenceIndex(proxy, date: date),
                      let event = CalendarLogic.recurrenceDate(self, index: offset + index), allowsReminder(for: event) else { continue }
                result.append(ReminderOccurrence(date: date, occurrence: event))
            }
        }
        // Start-relative rules can notify before an event beyond the queue horizon.
        let extended = DateInterval(start: interval.start, end: interval.end.addingTimeInterval(3601))
        for event in CalendarLogic.occurrences(of: self, in: extended) {
            for rule in relativeRules {
                if let date = rule.date(for: self, occurrence: event), date >= interval.start, date < interval.end {
                    result.append(ReminderOccurrence(date: date, occurrence: event))
                }
            }
        }
        return sortedReminders(result)
    }
    /// Detail view and queue construction use the same ordinal mapping, including month ends.
    public func reminderSchedule(for occurrence: Date) -> [ReminderOccurrence] {
        guard calendarLink?.disposition != .cancelled else { return [] }
        var result: [ReminderOccurrence] = []
        if repeatRule == .none {
            guard occurrence == startAt else { return [] }
            result = reminderDates.map { ReminderOccurrence(date: $0, occurrence: kind == .meeting ? startAt : nil) }
        } else {
            let offset = CalendarLogic.recurrenceIndex(self, date: startAt) ?? 0
            guard allowsReminder(for: occurrence), let index = CalendarLogic.recurrenceIndex(self, date: occurrence), index >= offset else { return [] }
            for anchor in reminderDates {
                if let date = CalendarLogic.recurrenceDate(fixedReminderProxy(anchor), index: index - offset) {
                    result.append(ReminderOccurrence(date: date, occurrence: occurrence))
                }
            }
        }
        for rule in relativeRules {
            if let date = rule.date(for: self, occurrence: occurrence) {
                result.append(ReminderOccurrence(date: date, occurrence: kind == .meeting ? occurrence : nil))
            }
        }
        return sortedReminders(result)
    }
}

public struct ReminderNotificationTarget: Equatable, Sendable {
    public let recordID: UUID
    public let occurrence: Date?
    public init(recordID: UUID, occurrence: Date? = nil) { self.recordID = recordID; self.occurrence = occurrence }
    public var userInfo: [String: String] {
        var info = ["recordID": recordID.uuidString]
        // Whole seconds match the workspace's ISO8601 storage precision.
        if let occurrence { info["occurrenceStart"] = ISO8601DateFormatter().string(from: occurrence) }
        return info
    }
    public init?(userInfo: [AnyHashable: Any]) {
        guard let text = userInfo["recordID"] as? String, let id = UUID(uuidString: text) else { return nil }
        recordID = id
        if let value = userInfo["occurrenceStart"] {
            guard let text = value as? String, let date = ISO8601DateFormatter().date(from: text) else { return nil }
            occurrence = date
        } else { occurrence = nil }
    }
}
public struct ReminderDestination: Equatable, Sendable {
    public let recordID: UUID
    public let occurrence: Date?
    public let focusDate: Date
    public let message: String?
}
extension Workspace {
    public func reminderDestination(for target: ReminderNotificationTarget) -> ReminderDestination? {
        guard let record = record(target.recordID) else { return nil }
        func destination(_ item: WorkRecord, occurrence: Date? = nil, message: String? = nil) -> ReminderDestination {
            ReminderDestination(recordID: item.id, occurrence: occurrence, focusDate: occurrence ?? item.startAt, message: message)
        }
        guard record.kind == .meeting else { return destination(record) }
        guard let requested = target.occurrence else {
            return destination(record, message: record.repeatRule == .none ? nil : "这条旧通知没有会议日期，已打开当前系列。")
        }
        func sameSecond(_ date: Date) -> Bool { floor(date.timeIntervalSince1970) == floor(requested.timeIntervalSince1970) }
        if record.repeatRule == .none {
            return destination(record, message: sameSecond(record.startAt) ? nil : "会议已改期，已打开当前时间。")
        }
        let window = DateInterval(start: requested.addingTimeInterval(-1), end: requested.addingTimeInterval(1))
        if let date = CalendarLogic.occurrences(of: record, in: window).first(where: sameSecond) {
            return destination(record, occurrence: date)
        }
        if let exception = records.first(where: { $0.seriesID == record.id && $0.originalOccurrence.map(sameSecond) == true }) {
            return destination(exception, message: "该次会议已单独修改，已打开当前安排。")
        }
        return destination(record, message: "该次会议已取消、改期或拆分，已打开当前系列。")
    }
}
