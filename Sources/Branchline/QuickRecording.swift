import SwiftUI
import AppKit
import ProgressCore

enum QuickSurface { case main, menu }

extension AppStore {
    var recordingContext: RecordingContext? {
        switch selection {
        case .project(let id): .project(id)
        case .branch(let id): .branch(id)
        case .record(let id): .record(id)
        case .merge(let id): .merge(id)
        case nil: nil
        }
    }
    private var recentLocationKey: String { "recording.locations.\(dataDirectory.path).\(isDemo ? "demo" : "personal")" }
    private var storedRecordingLocations: [RecordingLocation] {
        guard let data = UserDefaults.standard.data(forKey: recentLocationKey) else { return [] }
        return (try? JSONDecoder().decode([RecordingLocation].self, from: data)) ?? []
    }
    var recentRecordingLocations: [RecordingLocation] {
        storedRecordingLocations.filter { $0.exists(in: workspace) && !$0.isArchived(in: workspace) }
    }
    var lastRecordingLocation: RecordingLocation? {
        workspace.lastRecordingLocation(in: storedRecordingLocations)
    }
    func rememberRecordingLocation(_ location: RecordingLocation?) {
        guard let location, location.exists(in: workspace) else { return }
        let next = [location] + storedRecordingLocations.filter { $0 != location }
        if let data = try? JSONEncoder().encode(Array(next.prefix(8))) { UserDefaults.standard.set(data, forKey: recentLocationKey) }
    }
    var quickIsDirty: Bool { quickRecord != nil && quickRecord != quickBaseline }
    var quickCanSave: Bool {
        guard let record = quickRecord, !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let location = record.recordingLocation else { return false }
        return location.exists(in: workspace)
    }
    func beginQuickProgress(_ surface: QuickSurface) {
        guard editor == nil, !fileDialogPending else { return }
        if surface == .main { quickVisible = true }
        if quickIsDirty { registerQuickProtection(); return }
        quickSurface = surface
        let location = surface == .menu ? lastRecordingLocation : workspace.recordingLocation(context: recordingContext, projectFilter: projectFilter)
        var record = WorkRecord()
        if let location { record = location.applying(to: record) }
        quickBaseline = record; quickRecord = record; quickError = nil; quickNotice = ""
        if surface == .menu, location == nil, !storedRecordingLocations.isEmpty { quickNotice = "上次的位置已不可用，请重新选择归属。" }
    }
    func refreshQuickContext() {
        if quickVisible && quickSurface == .main && !quickIsDirty { beginQuickProgress(.main) }
    }
    func registerQuickProtection() {
        if let quickRecord { checkpointDraft(quickRecord, original: nil, dirty: quickIsDirty) }
        guard editor == nil else { return }
        guard quickRecord != nil else { EditorProtection.shared.clear(owner: quickOwner); return }
        EditorProtection.shared.update(owner: quickOwner, dirty: { [weak self] in self?.quickIsDirty == true }, save: { [weak self] in try self?.saveQuickProgress() }, reportError: { [weak self] in self?.quickError = $0 }, discard: { [weak self] in if let self, let id = self.quickRecord?.id.uuidString { self.removeDraft(id) } }, checkpoint: { [weak self] in self?.flushDrafts() })
    }
    func endQuickProgress() {
        quickRecord = nil; quickBaseline = nil; quickVisible = false; quickError = nil; quickNotice = ""
        EditorProtection.shared.clear(owner: quickOwner)
    }
    func cancelQuickProgress() {
        registerQuickProtection()
        if EditorProtection.shared.resolve() { endQuickProgress() }
    }
    func saveQuickProgress() throws {
        guard var record = quickRecord else { return }
        record.title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.title.isEmpty else { throw WorkspaceError("请先输入进展内容。") }
        guard let location = record.recordingLocation, location.exists(in: workspace) else { throw WorkspaceError("归属未选择或已被删除，请重新选择；输入内容已保留。") }
        try saveRecord(record, selectSaved: false)
        removeDraft(record.id.uuidString)
        var blank = WorkRecord(); blank = location.applying(to: blank)
        quickBaseline = blank; quickRecord = blank; quickError = nil
        quickNotice = notice
    }
    func submitQuickProgress() {
        // Return used to confirm an IME candidate must not submit the record.
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.hasMarkedText() { return }
        if quickRecord?.recordingLocation?.exists(in: workspace) != true {
            quickLocationAttempted = true; quickLocationFocusRequest += 1; quickError = nil; return
        }
        do { try saveQuickProgress() } catch { quickError = error.localizedDescription }
    }
    func expandQuickProgress() {
        guard let record = quickRecord else { return }
        let dirty = quickIsDirty
        flushDrafts()
        endQuickProgress()
        editor = .progressDraft(record, dirty)
    }
}

struct RecordingLocationPicker: View {
    @Bindable var store: AppStore
    @Binding var selection: RecordingLocation?
    var required = false
    var focusRequest = 0
    var attempted = false
    @FocusState private var locationSearchFocused: Bool
    @LocalState private var showing = false
    @LocalState private var search = ""
    @LocalState private var showArchived = false
    @LocalState private var popupID = UUID()
    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(selection.map { "记录到：" + $0.title(in: store.workspace) } ?? "选择归属", systemImage: "folder")
                    .lineLimit(2).multilineTextAlignment(.leading)
                if required && selection == nil { Text("必填 · 请选择项目或分支").font(.caption).foregroundStyle(attempted ? Color.red : Color.secondary) }
                if let selection {
                    let detail = selection.detail(in: store.workspace)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if !selection.exists(in: store.workspace) { Text("位置已失效，请重新选择").font(.caption).foregroundStyle(.red) }
                    else if selection.isArchived(in: store.workspace) { Text("已归档 · 当前明确选择的位置").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.buttonStyle(.plain).accessibilityLabel(required && selection == nil ? "选择归属，必填，请选择项目或分支" : "更改记录归属").help(selection.map { $0.title(in: store.workspace) + " " + $0.detail(in: store.workspace) } ?? "选择项目主干或分支")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("记录到哪里").font(.headline)
                TextField("搜索项目或分支", text: $search).textFieldStyle(.roundedBorder).focused($locationSearchFocused)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if search.isEmpty && !store.recentRecordingLocations.isEmpty {
                            Text("最近使用").font(.caption).foregroundStyle(.secondary)
                            ForEach(store.recentRecordingLocations, id: \.self) { row($0) }
                            Divider()
                        }
                        Text("项目与分支").font(.caption).foregroundStyle(.secondary)
                        let active = locations(archived: false)
                        if active.isEmpty { Text("没有匹配位置").foregroundStyle(.secondary) }
                        ForEach(active, id: \.self) { row($0) }
                        DisclosureGroup("已归档", isExpanded: $showArchived) {
                            ForEach(locations(archived: true), id: \.self) { row($0) }
                        }
                        DisclosureGroup("关联多个项目主干") {
                            ForEach(store.workspace.projects.filter { $0.status != .archived || showArchived }) { project in
                                Toggle(project.title, isOn: projectSelection(project.id)).toggleStyle(.checkbox)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 340)
                HStack { Spacer(); Button("完成") { showing = false } }
            }.padding(18).frame(width: 360)
                .onAppear { EditorProtection.shared.openedPopover(popupID); locationSearchFocused = true }
                .onDisappear { EditorProtection.shared.closedPopover(popupID) }
        }
        .onChange(of: focusRequest) { _, _ in search = ""; showing = true }
    }
    private func projectSelection(_ id: UUID) -> Binding<Bool> {
        Binding<Bool>(get: { selection?.branchID == nil && selection?.projectIDs.contains(id) == true }, set: { on in
            var ids: [UUID] = []
            if let current = selection, current.branchID == nil { ids = current.projectIDs }
            if on { ids.append(id) } else { ids.removeAll { $0 == id } }
            if ids.isEmpty { selection = nil } else { selection = RecordingLocation(projectIDs: ids) }
        })
    }
    private func locations(archived: Bool) -> [RecordingLocation] {
        let all = store.workspace.projects.map { RecordingLocation(projectIDs: [$0.id]) } + store.workspace.branches.map { RecordingLocation(branchID: $0.id) }
        return all.filter { $0.isArchived(in: store.workspace) == archived && (search.isEmpty || ($0.title(in: store.workspace) + " " + $0.detail(in: store.workspace)).localizedCaseInsensitiveContains(search)) }
    }
    private func row(_ location: RecordingLocation) -> some View {
        Button { selection = location; showing = false } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) { Text(location.title(in: store.workspace)); let detail = location.detail(in: store.workspace); if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) } }
                Spacer(); if selection == location { Image(systemName: "checkmark").foregroundStyle(.blue) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("选择归属：\(location.title(in: store.workspace))，\(location.detail(in: store.workspace))")
    }
}

struct ProgressDateButton: View {
    @Binding var record: WorkRecord
    @LocalState private var showing = false
    @LocalState private var popupID = UUID()
    var body: some View {
        Button { showing = true } label: { Label(label, systemImage: "calendar").fixedSize() }
            .buttonStyle(.plain).accessibilityLabel("更改发生日期：\(label)")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 14) {
                    DatePicker("发生日期", selection: $record.startAt, displayedComponents: record.dateOnly ? .date : [.date, .hourAndMinute])
                    HStack {
                        Button("今天") { setDay(Date()) }
                        Button("昨天") { var calendar = Calendar.current; calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current; setDay(calendar.date(byAdding: .day, value: -1, to: Date())!) }
                        Spacer(); Button("完成") { showing = false }
                    }
                }.padding(18).frame(width: 350).environment(\.timeZone, TimeZone(identifier: record.timeZoneID) ?? .current)
                    .onAppear { EditorProtection.shared.openedPopover(popupID) }
                    .onDisappear { EditorProtection.shared.closedPopover(popupID) }
            }
    }
    private var label: String {
        var calendar = Calendar.current; calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
        if record.dateOnly && calendar.isDateInToday(record.startAt) { return "今天" }
        return WorkDateText.date(record.startAt, timed: !record.dateOnly, zone: record.timeZoneID)
    }
    private func setDay(_ day: Date) {
        var calendar = Calendar.current; calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
        let time = calendar.dateComponents([.hour, .minute, .second], from: record.startAt)
        record.startAt = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) ?? day
    }
}

struct QuickProgressComposer: View {
    @Bindable var store: AppStore
    var surface: QuickSurface
    @FocusState private var focused: Bool
    private var draft: Binding<WorkRecord> { Binding(get: { store.quickRecord ?? WorkRecord() }, set: { store.quickRecord = $0 }) }
    private var location: Binding<RecordingLocation?> { Binding(get: { store.quickRecord?.recordingLocation }, set: { choice in
        guard let record = store.quickRecord else { return }
        if let choice { store.quickRecord = choice.applying(to: record) }
        else { var next = record; next.branchID = nil; next.projectIDs = []; store.quickRecord = next }
    }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) { RecordingLocationPicker(store: store, selection: location, required: true, focusRequest: store.quickLocationFocusRequest, attempted: store.quickLocationAttempted); Spacer(minLength: 0); ProgressDateButton(record: draft) }.font(.callout)
            TextField("记下一条进展…", text: draft.title).textFieldStyle(.roundedBorder).focused($focused).onSubmit { store.submitQuickProgress() }.accessibilityIdentifier("quickProgressContent")
            HStack {
                Button("详细编辑") { store.expandQuickProgress() }.buttonStyle(.plain).foregroundStyle(.secondary)
                if !store.isDemo && store.quickIsDirty { Button("存为草稿") { store.flushDrafts(); if store.draftError == nil { store.endQuickProgress(); if surface == .menu { store.beginQuickProgress(.menu) } } }.buttonStyle(.plain) }
                if let id = store.quickRecord?.id.uuidString, let status = store.draftStatus(id) { Text(status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if surface == .main { Button("收起") { store.cancelQuickProgress() }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Button("保存") { store.submitQuickProgress(); focused = true }.buttonStyle(.borderedProminent).disabled(!store.quickCanSave)
            }
            if let error = store.quickError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            else if !store.quickNotice.isEmpty { Text(store.quickNotice).font(.caption).foregroundStyle(.secondary) }
        }.task { if store.quickRecord == nil { store.beginQuickProgress(surface) }; await Task.yield(); focused = true }
    }
}
