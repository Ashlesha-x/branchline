import SwiftUI
import AppKit
import Observation
@preconcurrency import EventKit
import ProgressCore

struct CalendarChoice: Identifiable, Hashable { var id: String; var title: String; var source: String; var writable: Bool; var color: Color }

/// Reads Apple Calendar into 脉络 and writes linked meetings back.
@MainActor @Observable final class AppleCalendarService {
    @ObservationIgnored private lazy var events = EKEventStore()
    @ObservationIgnored private let defaults = UserDefaults.standard
    var calendars: [CalendarChoice] = []
    var message = ""
    var connecting = false
    var invalidated = false
    var sourceReviews: [CalendarSourceReview] = []
    /// Linked meetings that changed in Apple Calendar since the last sync (updates, conflicts, cancellations).
    var pendingChanges = 0
    var lastWriteError: String?
    @ObservationIgnored private var lastPendingScan = Date.distantPast

    var authorization: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var connected: Bool { authorization == .fullAccess }
    var denied: Bool { authorization == .denied || authorization == .restricted || authorization == .writeOnly }

    // MARK: Saved choices
    var selectedCalendarIDs: Set<String> {
        get { access(keyPath: \.calendars); return Set(defaults.stringArray(forKey: "calendar.selected") ?? []) }
        set { withMutation(keyPath: \.calendars) { defaults.set(Array(newValue).sorted(), forKey: "calendar.selected") }; invalidated = true }
    }
    var rangeDays: Int {
        get { access(keyPath: \.calendars); let value = defaults.integer(forKey: "calendar.rangeDays"); return value > 0 ? value : 30 }
        set { withMutation(keyPath: \.calendars) { defaults.set(min(366, max(1, newValue)), forKey: "calendar.rangeDays") }; invalidated = true }
    }
    var defaultWriteCalendarID: String? {
        get { access(keyPath: \.calendars); return defaults.string(forKey: "calendar.writeTarget") }
        set { withMutation(keyPath: \.calendars) { defaults.set(newValue, forKey: "calendar.writeTarget") } }
    }
    var lastSyncSummary: String? {
        get { access(keyPath: \.calendars); return defaults.string(forKey: "calendar.lastSync") }
        set { withMutation(keyPath: \.calendars) { defaults.set(newValue, forKey: "calendar.lastSync") } }
    }
    func savedLocation(demo: Bool) -> RecordingLocation? {
        defaults.data(forKey: "calendar.location." + (demo ? "demo" : "personal")).flatMap { try? JSONDecoder().decode(RecordingLocation.self, from: $0) }
    }
    func saveLocation(_ location: RecordingLocation?, demo: Bool) {
        defaults.set(location.flatMap { try? JSONEncoder().encode($0) }, forKey: "calendar.location." + (demo ? "demo" : "personal"))
    }
    var selectedCalendars: [CalendarChoice] { calendars.filter { selectedCalendarIDs.contains($0.id) } }
    var writableCalendars: [CalendarChoice] { calendars.filter(\.writable) }
    var writeTarget: CalendarChoice? { defaultWriteCalendarID.flatMap { id in calendars.first { $0.id == id && $0.writable } } }

    // MARK: Access
    func loadIfAuthorized() { if connected && calendars.isEmpty { reloadCalendars() } }
    func reloadCalendars() {
        guard connected else { calendars = []; return }
        calendars = events.calendars(for: .event).map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title, writable: $0.allowsContentModifications, color: Color(nsColor: $0.color ?? .systemGray))
        }.sorted { $0.source == $1.source ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.source.localizedStandardCompare($1.source) == .orderedAscending }
        let known = Set(calendars.map(\.id))
        let selected = selectedCalendarIDs.intersection(known)
        if selected != selectedCalendarIDs { defaults.set(Array(selected).sorted(), forKey: "calendar.selected") }
        message = calendars.isEmpty ? "当前没有可读取的日历。" : ""
    }
    func connect() async {
        if denied { openPrivacySettings(); return }
        connecting = true; defer { connecting = false }
        do {
            guard try await events.requestFullAccessToEvents() else { message = "未获得日历权限。"; return }
            reloadCalendars()
        } catch { message = error.localizedDescription }
    }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }

    // MARK: Reading
    func read(calendarIDs: Set<String>, from: Date, through: Date, workspace: Workspace? = nil) throws -> [CalendarImportItem] {
        let result = try scan(calendarIDs: calendarIDs, from: from, through: through, workspace: workspace)
        sourceReviews = result.reviews
        invalidated = false
        if let workspace { pendingChanges = Self.pending(result.items, reviews: result.reviews, in: workspace) }
        return result.items
    }
    /// Quietly re-reads the saved calendars to count changes for linked meetings.
    func refreshPending(workspace: Workspace, demo: Bool, force: Bool = false) {
        guard !demo, connected, !selectedCalendarIDs.isEmpty, workspace.records.contains(where: { $0.calendarLink != nil }) else { pendingChanges = 0; return }
        guard force || Date().timeIntervalSince(lastPendingScan) > 30 else { return }
        lastPendingScan = Date()
        let today = Calendar.current.startOfDay(for: Date())
        let through = Calendar.current.date(byAdding: .day, value: rangeDays, to: today) ?? today
        guard let result = try? scan(calendarIDs: selectedCalendarIDs, from: today, through: through, workspace: workspace) else { return }
        pendingChanges = Self.pending(result.items, reviews: result.reviews, in: workspace)
    }
    private static func pending(_ items: [CalendarImportItem], reviews: [CalendarSourceReview], in workspace: Workspace) -> Int {
        let states = items.map { workspace.calendarChange($0, location: nil).state }
        let reviewIDs = Set(reviews.filter { !$0.alreadyHandled }.map(\.id))
        return states.filter { $0 == .update || $0 == .conflict }.count + reviewIDs.count
    }
    private func scan(calendarIDs: Set<String>, from: Date, through: Date, workspace: Workspace?) throws -> (items: [CalendarImportItem], reviews: [CalendarSourceReview]) {
        guard connected, !calendarIDs.isEmpty else { throw WorkspaceError("请先连接并选择日历。") }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from), end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through))!
        guard start < end, calendar.dateComponents([.day], from: start, to: end).day! <= 367 else { throw WorkspaceError("请选择一年以内的有效日期范围。") }
        let sources = events.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !sources.isEmpty, Set(sources.map(\.calendarIdentifier)) == calendarIDs else { throw WorkspaceError("所选日历已不可用，请重新选择。") }
        let found = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: sources))
        guard found.count <= 1000 else { throw WorkspaceError("超过 1000 次事件，请缩短时间段或减少日历。") }
        // Some servers assign a new external identifier after a new event syncs; keep such events on their existing link.
        let linkedByEvent: [String: String] = Dictionary((workspace?.records ?? []).compactMap { record in
            guard let link = record.calendarLink, link.occurrence == nil, let eventID = link.eventID else { return nil }
            return (eventID, link.key)
        }, uniquingKeysWith: { first, _ in first })
        let linkedKeys = Set((workspace?.records ?? []).compactMap { $0.calendarLink?.key })
        var unique: [String: CalendarImportItem] = [:]
        for event in found {
            var item = importItem(event)
            if !linkedKeys.contains(item.key), item.occurrence == nil, let eventID = item.eventID, let key = linkedByEvent[eventID] { item.key = key }
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
                    if let event = candidates.first(where: { calendarIDs.contains($0.calendar.calendarIdentifier) && (link.calendarID == nil || link.calendarID == $0.calendar.calendarIdentifier) && (importItem($0).key == link.key || ($0.eventIdentifier == link.eventID && link.occurrence == nil)) }) {
                        var item = importItem(event); item.key = link.key; unique[link.key] = item
                    }
                }
                if let item = unique[link.key] {
                    if item.isCancelled && !reviews.contains(where: { $0.id == record.id }) { reviews.append(CalendarSourceReview(record: record, issue: .cancelled)) }
                } else { reviews.append(CalendarSourceReview(record: record, issue: .missing)) }
            }
        }
        let items = unique.values.sorted { $0.value.start == $1.value.start ? $0.key < $1.key : $0.value.start < $1.value.start }
        return (items, reviews)
    }
    private func importItem(_ event: EKEvent) -> CalendarImportItem {
        let external = event.calendarItemExternalIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? event.calendarItemIdentifier
        let occurrence = event.hasRecurrenceRules || event.isDetached ? event.occurrenceDate ?? event.startDate : nil
        let key = external + (occurrence.map { "|" + String(floor($0.timeIntervalSince1970)) } ?? "")
        let body = [event.notes, event.location.map { "地点：" + $0 }, event.url.map { "链接：" + $0.absoluteString }].compactMap { $0 }.filter { !$0.isEmpty && $0 != "地点：" }.joined(separator: "\n")
        let value = CalendarEventValue(title: event.title?.isEmpty == false ? event.title! : "未命名会议", body: body, start: event.startDate, end: event.isAllDay ? max(event.startDate, event.endDate.addingTimeInterval(-1)) : event.endDate, allDay: event.isAllDay, timeZoneID: event.timeZone?.identifier ?? TimeZone.current.identifier)
        return CalendarImportItem(key: key, calendarTitle: event.calendar.title, externalID: external, occurrence: occurrence, value: value, calendarID: event.calendar.calendarIdentifier, eventID: event.eventIdentifier, isCancelled: event.status == .canceled)
    }

    // MARK: Writing
    private func event(for link: CalendarEventLink) -> EKEvent? {
        if let occurrence = link.occurrence {
            let start = occurrence.addingTimeInterval(-2 * 86_400), end = occurrence.addingTimeInterval(2 * 86_400)
            let scope = link.calendarID.flatMap { events.calendar(withIdentifier: $0) }.map { [$0] }
            return events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: scope)).first { importItem($0).key == link.key }
        }
        if let id = link.eventID, let event = events.event(withIdentifier: id) { return event }
        let candidates = events.calendarItems(withExternalIdentifier: link.externalID).compactMap { $0 as? EKEvent }
        return candidates.first { $0.calendar.calendarIdentifier == link.calendarID } ?? candidates.first
    }
    private func apply(_ value: CalendarEventValue, to event: EKEvent) {
        event.title = value.title
        event.notes = value.notesForCalendar.isEmpty ? nil : value.notesForCalendar
        event.isAllDay = value.allDay
        event.timeZone = value.allDay ? nil : TimeZone(identifier: value.timeZoneID)
        event.startDate = value.start
        event.endDate = value.allDay ? value.end.addingTimeInterval(1) : max(value.end, value.start)
    }
    /// Creates an event in the default calendar and returns the link to store on the meeting.
    func createEvent(for record: WorkRecord) throws -> CalendarEventLink {
        guard connected else { throw WorkspaceError("请先在设置 › 日历中允许脉络访问日历。") }
        guard record.canWriteToCalendar else { throw WorkspaceError("重复会议暂不能写入 Apple 日历。") }
        guard let id = writeTarget?.id, let calendar = events.calendar(withIdentifier: id), calendar.allowsContentModifications else { throw WorkspaceError("请先在设置 › 日历中选择写入的日历。") }
        let event = EKEvent(eventStore: events)
        event.calendar = calendar
        apply(CalendarEventValue(record), to: event)
        try events.save(event, span: .thisEvent, commit: true)
        let item = importItem(event)
        return CalendarEventLink(key: item.key, calendarTitle: item.calendarTitle, externalID: item.externalID, occurrence: item.occurrence, calendarID: item.calendarID, eventID: item.eventID, lastImported: item.value)
    }
    enum PushResult { case written(CalendarEventValue), calendarChanged, missing }
    /// Writes the meeting's current fields to its event, unless the event also changed since the last sync.
    func push(_ record: WorkRecord) throws -> PushResult {
        guard connected, let link = record.calendarLink else { return .missing }
        guard let event = event(for: link) else { return .missing }
        guard event.calendar.allowsContentModifications else { throw WorkspaceError("「\(event.calendar.title)」是只读日历，未写回。") }
        let remote = importItem(event).value
        if CalendarField.allCases.contains(where: { !$0.equal(remote, link.lastImported) }) { return .calendarChanged }
        apply(CalendarEventValue(record), to: event)
        try events.save(event, span: .thisEvent, commit: true)
        return .written(importItem(event).value)
    }
    /// Removes the events of deleted meetings. Returns how many were removed.
    func deleteEvents(for records: [WorkRecord]) throws -> Int {
        guard connected else { return 0 }
        var removed = 0
        for record in records {
            guard let link = record.calendarLink, let event = event(for: link), event.calendar.allowsContentModifications else { continue }
            try events.remove(event, span: .thisEvent, commit: false); removed += 1
        }
        if removed > 0 { try events.commit() }
        return removed
    }
}

// MARK: - Sync window

struct CalendarImportView: View {
    @Bindable var store: AppStore
    @LocalState private var selected: Set<String> = []
    @LocalState private var from = Date()
    @LocalState private var through = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
    @LocalState private var items: [CalendarImportItem] = []
    @LocalState private var location: RecordingLocation?
    @LocalState private var message = ""
    @LocalState private var resolving: CalendarResolutionRequest?
    @LocalState private var onlyActionable = true
    @LocalState private var didLoad = false
    private var service: AppleCalendarService { store.calendarService }
    private func state(_ item: CalendarImportItem) -> CalendarSyncState { store.workspace.calendarChange(item, location: location).state }
    private var visibleItems: [CalendarImportItem] { onlyActionable ? items.filter { state($0) != .unchanged && state($0) != .cancelled } : items }
    private var counts: (new: Int, update: Int, conflict: Int, synced: Int) {
        var c = (new: 0, update: 0, conflict: 0, synced: 0)
        for item in items {
            switch state(item) { case .new: c.new += 1; case .update: c.update += 1; case .conflict, .sourceReview: c.conflict += 1; default: c.synced += 1 }
        }
        return c
    }
    var body: some View {
        Group {
            if !service.connected || service.calendars.isEmpty { connectView }
            else { syncView }
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 520, idealHeight: 720)
        .sheet(item: $resolving) { request in CalendarResolutionView(store: store, request: request) { read() } }
        .onAppear(perform: load)
        .onChange(of: store.browseSpaceToken) { _, _ in items = []; selected = []; location = service.savedLocation(demo: store.isDemo); resolving = nil; service.sourceReviews = []; service.invalidated = true }
        .onChange(of: from) { _, _ in service.invalidated = true }
        .onChange(of: through) { _, new in service.rangeDays = max(1, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: new).day ?? 30) }
        .onChange(of: location) { _, new in service.saveLocation(new, demo: store.isDemo) }
        .onChange(of: service.calendars) { _, _ in if !didLoad { load() } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in service.invalidated = true }
    }
    private var connectView: some View {
        ContentUnavailableView {
            Label(service.denied ? "脉络没有日历权限" : "连接 Apple 日历", systemImage: "calendar")
        } description: {
            Text(service.denied ? "在系统设置 › 隐私与安全性 › 日历中允许脉络。" : "读取所选日历里的会议，并把脉络里的修改写回。")
        } actions: {
            Button(service.denied ? "打开系统设置" : service.connecting ? "正在连接…" : "连接") { Task { await service.connect() } }
                .buttonStyle(.borderedProminent).disabled(service.connecting)
            if !service.message.isEmpty { Text(service.message).font(.callout).foregroundStyle(.secondary) }
        }
    }
    private var syncView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                CalendarPicker(service: service).frame(width: 240)
                Divider()
                VStack(spacing: 12) {
                    HStack {
                        DatePicker("从", selection: $from, displayedComponents: .date)
                        DatePicker("至", selection: $through, displayedComponents: .date)
                        Button("读取") { read() }.disabled(service.selectedCalendarIDs.isEmpty).keyboardShortcut("r")
                        Spacer()
                    }
                    RecordingLocationPicker(store: store, selection: $location, required: items.contains { selected.contains($0.id) && state($0) == .new })
                    HStack(spacing: 14) {
                        Toggle("只看需处理", isOn: $onlyActionable).toggleStyle(.checkbox)
                        Spacer()
                        let c = counts
                        if !items.isEmpty { Text("新会议 \(c.new) · 有更新 \(c.update) · 冲突 \(c.conflict) · 已同步 \(c.synced)").font(.caption).foregroundStyle(.secondary) }
                        Button("全选可同步") { selected = Set(items.filter { let s = state($0); return s == .new || s == .update }.map(\.id)) }
                        Button("清空") { selected = [] }
                    }.controlSize(.small)
                    List {
                        if !service.sourceReviews.isEmpty { Section("来源复核") { sourceReviewRows } }
                        Section {
                            if visibleItems.isEmpty {
                                Text(items.isEmpty ? "选择日历后点「读取」。" : "没有需要处理的事件。").foregroundStyle(.secondary)
                            }
                            ForEach(visibleItems) { item in row(item) }
                        }
                    }.listStyle(.inset)
                    if service.invalidated && !items.isEmpty {
                        HStack { Text("日历或日期已变化。").font(.caption).foregroundStyle(.orange); Button("重新读取") { read() }.controlSize(.small) }
                    }
                    if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(16)
            }
            Divider()
            HStack {
                if let summary = service.lastSyncSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("同步所选 \(selected.count) 项") { sync() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || service.invalidated || store.fileDialogPending)
            }.padding(16)
        }
    }
    private func row(_ item: CalendarImportItem) -> some View {
        let state = self.state(item)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { selected.contains(item.id) }, set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(state != .new && state != .update)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.value.title).lineLimit(2)
                Text(WorkDateText.short(item.value.start, timed: !item.value.allDay, zone: item.value.timeZoneID) + " · " + item.calendarTitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .conflict {
                Button("处理差异…") { if let record = store.workspace.records.first(where: { $0.calendarLink?.key == item.key }) { resolving = CalendarResolutionRequest(item: item, record: record) } }.controlSize(.small)
            }
            Text(state.rawValue).font(.caption).foregroundStyle(state == .conflict || state == .sourceReview ? Color.orange : state == .new || state == .update ? Color.accentColor : Color.secondary)
        }.padding(.vertical, 3)
    }
    private var sourceReviewRows: some View {
        ForEach(service.sourceReviews) { review in
            VStack(alignment: .leading, spacing: 5) {
                Text(review.record.title).fontWeight(.medium)
                Text(review.issue == .cancelled ? "日历中已取消。" : "日历中找不到了，可能已删除或移动。").font(.caption).foregroundStyle(.secondary)
                if review.alreadyHandled { Text(review.record.calendarLink?.disposition == .cancelled ? "已标记取消，提醒已停止" : "已保留").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("保留") { decide(review, .keptHistory) }
                    Button("标记取消并停止提醒") { decide(review, .cancelled) }
                    if review.record.calendarLink?.disposition == .cancelled { Button("恢复") { decide(review, .keptHistory, restore: true) } }
                }.controlSize(.small).disabled(service.invalidated)
            }.padding(.vertical, 3)
        }
    }
    private func load() {
        service.loadIfAuthorized()
        guard service.connected, !service.calendars.isEmpty else { return }
        didLoad = true
        from = Calendar.current.startOfDay(for: Date())
        through = Calendar.current.date(byAdding: .day, value: service.rangeDays, to: from) ?? from
        if location == nil { location = service.savedLocation(demo: store.isDemo).flatMap { $0.exists(in: store.workspace) ? $0 : nil } }
        if !service.selectedCalendarIDs.isEmpty { read() }
    }
    private func decide(_ review: CalendarSourceReview, _ decision: CalendarDisposition, restore: Bool = false) {
        do { try store.commit { try $0.handleCalendarSource(review, decision: decision, restore: restore) }; read() }
        catch { message = error.localizedDescription }
    }
    private func read() {
        do {
            items = try service.read(calendarIDs: service.selectedCalendarIDs, from: from, through: through, workspace: store.workspace)
            selected = Set(items.filter { state($0) == .update }.map(\.id)); message = ""
        } catch { message = error.localizedDescription }
    }
    private func sync() {
        do {
            var counts = (inserted: 0, updated: 0, conflicts: 0)
            try store.commit { counts = try $0.syncingCalendar(items.filter { selected.contains($0.id) }, location: location) }
            let open = items.filter { let s = state($0); return s == .conflict || s == .sourceReview }.count
            let summary = "上次同步 " + WorkDateText.short(Date(), timed: true, weekday: false) + " · 新增 \(counts.inserted)、更新 \(counts.updated)" + (open > 0 ? "，\(open) 项待处理" : "")
            if !store.isDemo { service.lastSyncSummary = summary }
            message = ""
            read()
        } catch { message = error.localizedDescription }
    }
}

/// Calendars grouped by account, with checkboxes for reading.
struct CalendarPicker: View {
    @Bindable var service: AppleCalendarService
    var body: some View {
        List {
            ForEach(Dictionary(grouping: service.calendars, by: \.source).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }, id: \.key) { group in
                Section(group.key) {
                    ForEach(group.value) { calendar in
                        Toggle(isOn: Binding(get: { service.selectedCalendarIDs.contains(calendar.id) }, set: { on in
                            var ids = service.selectedCalendarIDs; if on { ids.insert(calendar.id) } else { ids.remove(calendar.id) }; service.selectedCalendarIDs = ids
                        })) { Label { Text(calendar.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(calendar.color) } }.toggleStyle(.checkbox)
                    }
                }
            }
        }.listStyle(.sidebar)
    }
}
