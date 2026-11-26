import Foundation

public enum DailyBackupSchedule {
    /// The most recent scheduled run may be yesterday's missed run. A catch-up
    /// still counts as today's backup, so a day never receives two automatic runs.
    public static func shouldBackup(now: Date, lastSuccess: Date?, enabledSince: Date, minuteOfDay: Int, hasChanges: Bool, calendar: Calendar = .current) -> Bool {
        guard hasChanges, (0..<1440).contains(minuteOfDay) else { return false }
        if let lastSuccess, calendar.isDate(lastSuccess, inSameDayAs: now) { return false }
        let today = calendar.startOfDay(for: now)
        guard let scheduled = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: today),
              let due = now >= scheduled ? scheduled : calendar.date(byAdding: .day, value: -1, to: scheduled) else { return false }
        guard due >= calendar.startOfDay(for: enabledSince) else { return false }
        return lastSuccess.map { $0 < due } ?? true
    }
}
