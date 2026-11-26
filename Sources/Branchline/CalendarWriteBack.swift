import SwiftUI
import ProgressCore

extension AppStore {
    /// After a save, writes changed linked meetings back to Apple Calendar.
    func scheduleCalendarWriteBack(since previous: Workspace) {
        guard !isDemo, calendarService.connected else { return }
        let ids = workspace.calendarPushCandidates(since: previous).map(\.id)
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in self?.writeBackToCalendar(ids) }
    }
    func writeBackToCalendar(_ ids: [UUID]) {
        guard !isDemo else { return }
        var written: [(UUID, CalendarEventValue)] = []
        var changedInCalendar = 0, missing = 0
        var failure: String?
        for id in ids {
            guard let record = workspace.record(id) else { continue }
            do {
                switch try calendarService.push(record) {
                case .written(let value): written.append((id, value))
                case .calendarChanged: changedInCalendar += 1
                case .missing: missing += 1
                }
            } catch { failure = error.localizedDescription }
        }
        if !written.isEmpty {
            do { try commit { db in for (id, value) in written { try db.markCalendarWritten(id, value: value) } } }
            catch { failure = error.localizedDescription }
        }
        if let failure { notice = "写回日历未完成：" + failure }
        else if changedInCalendar > 0 { notice = "日历中也改过 \(changedInCalendar) 个会议，未覆盖。请在日历同步里处理差异。" }
        else if missing > 0 { notice = "日历中找不到 \(missing) 个已关联的会议，未写回。" }
        calendarService.refreshPending(workspace: workspace, demo: isDemo, force: true)
    }
    /// Creates an Apple Calendar event for a saved meeting and links them.
    func writeMeetingToCalendar(_ id: UUID) {
        guard !isDemo, let record = workspace.record(id), record.calendarLink == nil else { return }
        do {
            let link = try calendarService.createEvent(for: record)
            try commit { try $0.markCalendarWritten(id, value: link.lastImported, link: link) }
            notice = "已写入 Apple 日历「\(link.calendarTitle)」。"
        } catch { self.error = "会议已保存，但没有写入日历：" + error.localizedDescription }
    }
}
