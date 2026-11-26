import SwiftUI
import Observation
@preconcurrency import EventKit
import ProgressCore

struct CalendarChoice: Identifiable { var id: String; var title: String }

@MainActor @Observable final class AppleCalendarService {
    @ObservationIgnored private lazy var events = EKEventStore()
    var calendars: [CalendarChoice] = []
    var message = ""
    var connecting = false
    var invalidated = false
    var sourceReviews: [CalendarSourceReview] = []
    var connected: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    func connect() async {
        connecting = true; defer { connecting = false }
        do {
            guard try await events.requestFullAccessToEvents() else { message = "请在系统设置的日历权限中允许脉络访问，然后重试。"; return }
            calendars = events.calendars(for: .event).map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title + " · " + $0.source.title) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            message = calendars.isEmpty ? "当前没有可读取的日历。" : ""
        } catch { message = error.localizedDescription }
    }
    func read(calendarIDs: Set<String>, from: Date, through: Date, workspace: Workspace? = nil) throws -> [CalendarImportItem] {
        guard connected, !calendarIDs.isEmpty else { throw WorkspaceError("请先连接并选择日历。") }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from), end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through))!
        guard start < end, calendar.dateComponents([.day], from: start, to: end).day! <= 366 else { throw WorkspaceError("请选择一年以内的有效日期范围。") }
        let sources = events.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !sources.isEmpty, Set(sources.map(\.calendarIdentifier)) == calendarIDs else { throw WorkspaceError("所选日历已不可用，请重新连接。") }
        let found = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: sources))
        guard found.count <= 1000 else { throw WorkspaceError("超过 1000 次事件，请缩短时间段或减少日历。") }
        var unique: [String: CalendarImportItem] = [:]
        for event in found {
            let item = importItem(event)
            if let existing = unique[item.key], existing.value != item.value || existing.isCancelled != item.isCancelled { throw WorkspaceError("所选日历包含同标识但内容不同的事件，请只选择其中一个来源日历后读取。") }
            unique[item.key] = item
        }
        var reviews: [CalendarSourceReview] = []
        if let workspace {
            for item in unique.values where item.isCancelled {
                if let record = workspace.records.first(where: { $0.kind == .meeting && $0.calendarLink?.key == item.key && ($0.calendarLink?.calendarID == nil || $0.calendarLink?.calendarID == item.calendarID) }) { reviews.append(CalendarSourceReview(record: record, issue: .cancelled)) }
            }
            let linked = workspace.records.filter { record in
                guard record.kind == .meeting, let link = record.calendarLink, link.lastImported.start >= start, link.lastImported.start < end else { return false }
                return link.calendarID.map { calendarIDs.contains($0) } ?? (sources.filter { $0.title == link.calendarTitle }.count == 1)
            }
            guard linked.count <= 1000 else { throw WorkspaceError("需复核的已导入会议超过 1000 次，请缩短范围。") }
            for record in linked {
                let link = record.calendarLink!
                if unique[link.key] == nil {
                    let direct = link.eventID.flatMap { events.event(withIdentifier: $0) }
                    let candidates = (direct.map { [$0] } ?? []) + events.calendarItems(withExternalIdentifier: link.externalID).compactMap { $0 as? EKEvent }
                    if let event = candidates.first(where: { calendarIDs.contains($0.calendar.calendarIdentifier) && (link.calendarID == nil || link.calendarID == $0.calendar.calendarIdentifier) && importItem($0).key == link.key }) { unique[link.key] = importItem(event) }
                }
                if let item = unique[link.key] {
                    if item.isCancelled && !reviews.contains(where: { $0.id == record.id }) { reviews.append(CalendarSourceReview(record: record, issue: .cancelled)) }
                } else { reviews.append(CalendarSourceReview(record: record, issue: .missing)) }
            }
        }
        sourceReviews = reviews
        invalidated = false
        return unique.values.sorted { $0.value.start == $1.value.start ? $0.key < $1.key : $0.value.start < $1.value.start }
    }
    private func importItem(_ event: EKEvent) -> CalendarImportItem {
        let external = event.calendarItemExternalIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? event.calendarItemIdentifier
        let occurrence = event.hasRecurrenceRules || event.isDetached ? event.occurrenceDate ?? event.startDate : nil
        let key = external + (occurrence.map { "|" + String(floor($0.timeIntervalSince1970)) } ?? "")
        let body = [event.notes, event.location.map { "地点：" + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let value = CalendarEventValue(title: event.title?.isEmpty == false ? event.title! : "未命名会议", body: body, start: event.startDate, end: event.isAllDay ? max(event.startDate, event.endDate.addingTimeInterval(-1)) : event.endDate, allDay: event.isAllDay, timeZoneID: event.timeZone?.identifier ?? TimeZone.current.identifier)
        return CalendarImportItem(key: key, calendarTitle: event.calendar.title, externalID: external, occurrence: occurrence, value: value, calendarID: event.calendar.calendarIdentifier, eventID: event.eventIdentifier, isCancelled: event.status == .canceled)
    }

}

struct CalendarImportView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @LocalState private var selectedCalendars: Set<String> = []
    @LocalState private var selected: Set<String> = []
    @LocalState private var from = Date()
    @LocalState private var through = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
    @LocalState private var items: [CalendarImportItem] = []
    @LocalState private var location: RecordingLocation?
    @LocalState private var message = ""
    @LocalState private var resolving: CalendarResolutionRequest?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Apple 日历 → 脉络").font(.title3.weight(.semibold)); Text(store.isDemo ? "示例空间" : "个人空间").font(.caption).foregroundStyle(.secondary); Spacer(); Button("关闭") { dismiss() } }.padding(20)
            Divider()
            if !store.calendarService.connected || store.calendarService.calendars.isEmpty {
                Spacer()
                Button(store.calendarService.connecting ? "正在连接…" : "连接 Apple 日历") { Task { await store.calendarService.connect() } }.disabled(store.calendarService.connecting)
                if store.isDemo { Text("试导入仅保留在示例空间。").font(.callout).foregroundStyle(.secondary) }
                Text(store.calendarService.message).font(.callout).foregroundStyle(.secondary).padding()
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("选择日历").font(.headline)
                            ForEach(store.calendarService.calendars) { source in
                                Toggle(source.title, isOn: Binding(get: { selectedCalendars.contains(source.id) }, set: { if $0 { selectedCalendars.insert(source.id) } else { selectedCalendars.remove(source.id) }; store.calendarService.invalidated = true })).toggleStyle(.checkbox)
                            }
                        }.padding(18)
                    }.frame(width: 220)
                    Divider()
                    VStack(spacing: 12) {
                        HStack {
                            DatePicker("从", selection: $from, displayedComponents: .date)
                            DatePicker("至", selection: $through, displayedComponents: .date)
                            Button("读取并复核") { read() }.disabled(selectedCalendars.isEmpty)
                        }
                        RecordingLocationPicker(store: store, selection: $location, required: items.contains { selected.contains($0.id) && store.workspace.calendarChange($0, location: location).state == .new })
                        HStack {
                            Button("全选可同步") { selected = Set(items.filter { let state = store.workspace.calendarChange($0, location: location).state; return state == .new || state == .update }.map(\.id)) }
                            Button("清空选择") { selected = [] }
                            Spacer(); Text("\(items.count) 次事件").font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                if !store.calendarService.sourceReviews.isEmpty { sourceReviewRows }
                                ForEach(items) { item in
                                    let state = store.workspace.calendarChange(item, location: location).state
                                    VStack(alignment: .leading, spacing: 5) {
                                        Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })) {
                                            HStack { Text(item.value.title).lineLimit(2); Spacer(); Text(state.rawValue).font(.caption).foregroundStyle(state == .conflict ? Color.orange : Color.secondary) }
                                        }.toggleStyle(.checkbox).disabled(state != .new && state != .update)
                                        Text(WorkDateText.date(item.value.start, timed: !item.value.allDay, zone: item.value.timeZoneID) + " · " + item.calendarTitle).font(.caption).foregroundStyle(.secondary)
                                        if state == .conflict {
                                            Button("逐项处理差异…") { if let record = store.workspace.records.first(where: { $0.calendarLink?.key == item.key }) { resolving = CalendarResolutionRequest(item: item, record: record) } }
                                        }
                                    }
                                    Divider()
                                }
                            }
                        }
                        if store.calendarService.invalidated { Text("来源或日期已变化，请重新读取事件。").font(.caption).foregroundStyle(.orange) }
                        if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
                    }.padding(18)
                }
            }
            Divider()
            HStack {
                Text("手动同步；来源异常需确认后处理。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("同步所选 \(selected.count) 次") { sync() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || store.calendarService.invalidated || store.fileDialogPending)
            }.padding(18)
        }.frame(width: 900, height: 660)
            .sheet(item: $resolving) { request in CalendarResolutionView(store: store, request: request) { read() } }
            .onChange(of: store.browseSpaceToken) { _, _ in items = []; selected = []; selectedCalendars = []; location = nil; resolving = nil; store.calendarService.sourceReviews = []; store.calendarService.invalidated = true }
            .onChange(of: from) { _, _ in store.calendarService.invalidated = true }
            .onChange(of: through) { _, _ in store.calendarService.invalidated = true }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in store.calendarService.invalidated = true }
    }
    private var sourceReviewRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来源复核").font(.headline)
            ForEach(store.calendarService.sourceReviews) { review in
                VStack(alignment: .leading, spacing: 5) {
                    Text(review.record.title).fontWeight(.medium)
                    Text(review.issue == .cancelled ? "日历来源标记为已取消。" : "复核后仍未找到来源，可能已删除、移动或暂不可用；不会自动取消。").font(.caption).foregroundStyle(.secondary)
                    if review.alreadyHandled { Text(review.record.calendarLink?.disposition == .cancelled ? "已标记取消 · 后续提醒已停止" : "已保留历史").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("保留历史") { decide(review, .keptHistory) }
                        Button("标记取消并停止提醒") { decide(review, .cancelled) }
                        if review.record.calendarLink?.disposition == .cancelled { Button("恢复原安排") { decide(review, .keptHistory, restore: true) } }
                    }.disabled(store.calendarService.invalidated)
                }
                Divider()
            }
        }
    }
    private func decide(_ review: CalendarSourceReview, _ decision: CalendarDisposition, restore: Bool = false) {
        do { try store.commit { try $0.handleCalendarSource(review, decision: decision, restore: restore) }; read() }
        catch { message = error.localizedDescription }
    }
    private func read() {
        do { items = try store.calendarService.read(calendarIDs: selectedCalendars, from: from, through: through, workspace: store.workspace); selected = []; message = "" }
        catch { message = error.localizedDescription }
    }
    private func sync() {
        do {
            var counts = (inserted: 0, updated: 0, conflicts: 0)
            try store.commit { counts = try $0.syncingCalendar(items.filter { selected.contains($0.id) }, location: location) }
            message = "新增 \(counts.inserted) 次，更新 \(counts.updated) 次，保留冲突 \(counts.conflicts) 次。"
            selected = []
        } catch { message = error.localizedDescription }
    }
}
