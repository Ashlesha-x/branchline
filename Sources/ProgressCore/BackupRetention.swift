import Foundation

/// File naming and pruning for the iCloud Drive backup folder.
/// Only automatic backups are ever pruned; manual backups stay until the user removes them.
public enum ICloudBackupFiles {
    public static let automaticMarker = "-自动-"

    /// "脉络-个人空间-20261126-2000-MacBook-自动-<uuid>.json"
    public static func fileName(space: String, stamp: String, device: String, automatic: Bool, id: UUID = UUID()) -> String {
        let device = sanitize(device)
        return "脉络-\(space)-\(stamp)" + (device.isEmpty ? "" : "-\(device)") + (automatic ? automaticMarker : "-") + id.uuidString + ".json"
    }

    public static func sanitize(_ device: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = device.unicodeScalars.map { banned.contains($0) ? "_" : String($0) }.joined()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        return String(cleaned.prefix(40))
    }

    public static func isAutomatic(_ name: String) -> Bool { name.contains(automaticMarker) }
    public static func isPersonal(_ name: String) -> Bool { name.hasPrefix("脉络-个人空间-") }

    /// Device label embedded in a file name, if any (between the timestamp and the marker/uuid).
    public static func device(in name: String) -> String? {
        let parts = name.replacingOccurrences(of: ".json", with: "").components(separatedBy: "-")
        // 脉络, 空间, stamp (yyyyMMdd-HHmm[ss] or one part), device?, (自动)?, uuid(5 parts)
        guard parts.count >= 3 + 5 else { return nil }
        var rest = Array(parts.dropLast(5).dropFirst(2))
        if rest.last == "自动" { rest.removeLast() }
        // The stamp is "yyyyMMdd-HHmm[ss]" (two parts) when it looks like one, otherwise a single part.
        let isDigits: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        let stampWidth = rest.count >= 2 && rest[0].count == 8 && isDigits(rest[0]) && isDigits(rest[1]) ? 2 : 1
        guard rest.count > stampWidth else { return nil }
        rest.removeFirst(stampWidth)
        let joined = rest.joined(separator: "-")
        return joined.isEmpty ? nil : joined
    }

    /// Keeps the newest `keepRecent` automatic backups of this device, plus the newest one of each
    /// earlier calendar month. Returns the files that may be deleted.
    public static func prunable(_ files: [(name: String, date: Date)], device: String, keepRecent: Int = 30, calendar: Calendar = .current) -> [String] {
        let tag = sanitize(device)
        let mine = files.filter { file -> Bool in
            guard isAutomatic(file.name) else { return false }
            let label: String = Self.device(in: file.name) ?? ""
            return label == tag
        }
        let automatic = mine.sorted { a, b -> Bool in
            a.date == b.date ? a.name > b.name : a.date > b.date
        }
        guard automatic.count > keepRecent else { return [] }
        var keptMonths = Set<DateComponents>()
        for file in automatic.prefix(keepRecent) { keptMonths.insert(calendar.dateComponents([.year, .month], from: file.date)) }
        var remove: [String] = []
        for file in automatic.dropFirst(keepRecent) {
            let month = calendar.dateComponents([.year, .month], from: file.date)
            if keptMonths.insert(month).inserted { continue }
            remove.append(file.name)
        }
        return remove
    }
}

extension DailyBackupSchedule {
    public enum Status: Equatable, Sendable {
        /// The next automatic run, which may be "now" if one is overdue.
        case scheduled(Date)
        /// Today's run found nothing new since the last backup.
        case skippedNoChanges(next: Date)
    }
    /// What the settings page shows below the schedule. `hasChanges` compares the data with the last backup.
    public static func status(now: Date, lastSuccess: Date?, enabledSince: Date, minuteOfDay: Int, hasChanges: Bool, calendar: Calendar = .current) -> Status {
        let today = calendar.startOfDay(for: now)
        let scheduledToday = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: today) ?? now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: scheduledToday) ?? now
        let doneToday = lastSuccess.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        if doneToday { return .scheduled(tomorrow) }
        let dueNow = shouldBackup(now: now, lastSuccess: lastSuccess, enabledSince: enabledSince, minuteOfDay: minuteOfDay, hasChanges: true, calendar: calendar)
        if dueNow && !hasChanges { return .skippedNoChanges(next: now >= scheduledToday ? tomorrow : scheduledToday) }
        if dueNow { return .scheduled(now) }
        return .scheduled(now >= scheduledToday ? tomorrow : scheduledToday)
    }
}
