import Foundation
import ProgressCore

@MainActor func iCloudBackupNamesAndRetentionKeepRecentAndMonthly() throws {
    let name = ICloudBackupFiles.fileName(space: "个人空间", stamp: "20261126-200000", device: "Yuqiao's Mac-mini", automatic: true)
    try expect(ICloudBackupFiles.isAutomatic(name) && ICloudBackupFiles.isPersonal(name))
    try expect(ICloudBackupFiles.device(in: name) == ICloudBackupFiles.sanitize("Yuqiao's Mac-mini"))
    let manual = ICloudBackupFiles.fileName(space: "个人空间", stamp: "20261126-200000", device: "Mac", automatic: false)
    try expect(!ICloudBackupFiles.isAutomatic(manual) && ICloudBackupFiles.device(in: manual) == "Mac")
    try expect(ICloudBackupFiles.device(in: "脉络-个人空间-20261126-200000-\(UUID().uuidString).json") == nil)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 20))!
    var files: [(name: String, date: Date)] = []
    for day in 0..<90 {
        let date = calendar.date(byAdding: .day, value: -day, to: base)!
        files.append((ICloudBackupFiles.fileName(space: "个人空间", stamp: "d\(day)", device: "Mac", automatic: true), date))
    }
    files.append((manual, calendar.date(byAdding: .day, value: -200, to: base)!))
    files.append((ICloudBackupFiles.fileName(space: "个人空间", stamp: "x", device: "Other", automatic: true), calendar.date(byAdding: .day, value: -300, to: base)!))
    let removed = Set(ICloudBackupFiles.prunable(files, device: "Mac", calendar: calendar))
    try expect(!removed.contains(manual))
    try expect(!removed.contains { ICloudBackupFiles.device(in: $0) == "Other" })
    let kept = files.filter { ICloudBackupFiles.device(in: $0.name) == "Mac" && ICloudBackupFiles.isAutomatic($0.name) && !removed.contains($0.name) }
    try expect(files.prefix(30).allSatisfy { !removed.contains($0.name) })
    // 30 recent days span Oct/Nov; Sep and Aug each keep exactly one older file.
    let months = Dictionary(grouping: kept.dropFirst(30)) { calendar.component(.month, from: $0.date) }
    try expect(months.values.allSatisfy { $0.count == 1 })
    try expect(removed.count == 90 - kept.count)
}

@MainActor func dailyBackupStatusReportsNextRunAndSkips() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    func at(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
    let enabled = at(1, 9)
    try expect(DailyBackupSchedule.status(now: at(26, 10), lastSuccess: at(25, 20), enabledSince: enabled, minuteOfDay: 20 * 60, hasChanges: true, calendar: calendar) == .scheduled(at(26, 20)))
    try expect(DailyBackupSchedule.status(now: at(26, 21), lastSuccess: at(26, 20), enabledSince: enabled, minuteOfDay: 20 * 60, hasChanges: true, calendar: calendar) == .scheduled(at(27, 20)))
    try expect(DailyBackupSchedule.status(now: at(26, 21), lastSuccess: at(25, 20), enabledSince: enabled, minuteOfDay: 20 * 60, hasChanges: false, calendar: calendar) == .skippedNoChanges(next: at(27, 20)))
    try expect(DailyBackupSchedule.status(now: at(26, 21), lastSuccess: at(25, 20), enabledSince: enabled, minuteOfDay: 20 * 60, hasChanges: true, calendar: calendar) == .scheduled(at(26, 21)))
}

@MainActor func shortDatesDropCurrentYearAndKeepOthers() throws {
    let zone = "Asia/Singapore"
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9))!
    let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 14))!
    try expect(WorkDateText.short(date, timed: true, zone: zone, now: now) == "11月24日 周二 14:00")
    try expect(WorkDateText.short(date, zone: zone, now: now, weekday: false) == "11月24日")
    let old = calendar.date(from: DateComponents(year: 2025, month: 3, day: 2))!
    try expect(WorkDateText.short(old, zone: zone, now: now, weekday: false) == "2025年3月2日")
}

@MainActor func calendarWriteBackCandidatesAndNotes() throws {
    var db = Workspace.demo()
    let location = RecordingLocation(projectIDs: [db.projects[0].id])
    let start = Date()
    let value = CalendarEventValue(title: "评审", body: "议程\n地点：会议室 A\n链接：https://example.com/m", start: start, end: start.addingTimeInterval(3600), allDay: false, timeZoneID: "Asia/Singapore")
    try expect(value.notesForCalendar == "议程")
    let source = CalendarImportItem(key: "k1", calendarTitle: "工作", externalID: "k1", occurrence: nil, value: value, calendarID: "cal", eventID: "ev")
    _ = try db.syncingCalendar([source], location: location)
    let id = try require(db.records.first { $0.calendarLink?.key == "k1" }?.id)
    let before = db
    var edited = try require(db.record(id)); edited.title = "评审（改期）"; edited.startAt.addTimeInterval(1800); edited.endAt?.addTimeInterval(1800)
    try db.putRecord(edited)
    try expect(db.calendarPushCandidates(since: before).map(\.id) == [id])
    let pushed = db
    try db.markCalendarWritten(id, value: CalendarEventValue(try require(db.record(id))))
    try expect(db.calendarPushCandidates(since: pushed).isEmpty)
    try expect(db.calendarChange(source, location: nil).state != .new)
    var status = try require(db.record(id)); let statusBefore = db; status.status = .completed; status.completedAt = Date(); try db.putRecord(status)
    try expect(db.calendarPushCandidates(since: statusBefore).isEmpty)
    var plain = WorkRecord(kind: .meeting, title: "本地会议"); plain = location.applying(to: plain); plain.endAt = plain.startAt.addingTimeInterval(1800)
    try db.putRecord(plain)
    try expect(plain.canWriteToCalendar)
    let link = CalendarEventLink(key: "k2", calendarTitle: "工作", externalID: "k2", occurrence: nil, calendarID: "cal", eventID: "ev2", lastImported: CalendarEventValue(plain))
    try db.markCalendarWritten(plain.id, value: CalendarEventValue(plain), link: link)
    try expect(db.record(plain.id)?.calendarLink?.key == "k2")
    let beforeDelete = db
    db.records.removeAll { $0.id == plain.id }
    try expect(db.removedCalendarLinks(since: beforeDelete).map(\.id) == [plain.id])
}

@MainActor func workspaceRegistryValidatesNamesAndGuardsDeletion() throws {
    var registry = WorkspaceRegistry()
    try expect(registry.entries.count == 1 && registry.entries[0].isDefault && registry.entries[0].name == "个人空间")
    let work = try registry.add(name: "  工作  ")
    try expect(work.name == "工作" && !work.isDefault)
    try expectThrows { try registry.add(name: "工作") }
    try expectThrows { try registry.add(name: "   ") }
    try expectThrows { try registry.add(name: "示例空间") }
    try registry.rename(work.id, to: "公司")
    try expect(registry.entry(work.id)?.name == "公司")
    try expectThrows { try registry.rename(work.id, to: "个人空间") }
    try expectThrows { _ = try registry.remove(work.id, active: work.id, confirmation: "公司") }
    try expectThrows { _ = try registry.remove(work.id, active: WorkspaceEntry.defaultID, confirmation: "公") }
    let removed = try registry.remove(work.id, active: WorkspaceEntry.defaultID, confirmation: "公司")
    try expect(removed.id == work.id && registry.entries.count == 1)
    try expectThrows { _ = try registry.remove(WorkspaceEntry.defaultID, active: "x", confirmation: "个人空间") }
    // Workspace names with dashes stay one part of the file name; pruning can be limited to one workspace.
    let dashed = ICloudBackupFiles.fileName(space: "A-B 组", stamp: "20261126-2000", device: "Mac", automatic: true)
    try expect(ICloudBackupFiles.spaceName(in: dashed) == "A_B_组" && ICloudBackupFiles.device(in: dashed) == "Mac")
    let other = (1...40).map { (name: ICloudBackupFiles.fileName(space: "公司", stamp: "s\($0)", device: "Mac", automatic: true), date: Date(timeIntervalSince1970: Double($0) * 60)) }
    try expect(ICloudBackupFiles.prunable(other, device: "Mac", space: "个人空间").isEmpty)
    try expect(!ICloudBackupFiles.prunable(other, device: "Mac", space: "公司").isEmpty)
    let reopened = try JSONDecoder().decode(WorkspaceRegistry.self, from: JSONEncoder().encode(registry))
    try expect(reopened == registry)
}

@MainActor func onboardingShowsOnlyNewStopsToReturningUsers() throws {
    let stops: [(stop: String, introduced: String)] = [("projects", "0.1.0"), ("spaces", "0.17.1"), ("future", "0.18.0")]
    try expect(OnboardingPlan.stopsToShow(stops, seen: nil, returningUser: false, current: "0.17.1").isEmpty)
    try expect(OnboardingPlan.stopsToShow(stops, seen: nil, returningUser: true, current: "0.17.1") == ["spaces"])
    try expect(OnboardingPlan.stopsToShow(stops, seen: "0.17.1", returningUser: true, current: "0.17.1").isEmpty)
    try expect(OnboardingPlan.stopsToShow(stops, seen: "0.17.1", returningUser: true, current: "0.18.0") == ["future"])
    try expect(OnboardingPlan.stopsToShow(stops, seen: "0.16.0", returningUser: true, current: "0.18.0") == ["spaces", "future"])
}
