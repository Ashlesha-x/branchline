import SwiftUI
import ProgressCore

func editorSnapshot<T: Encodable>(_ value: T) -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return (try? encoder.encode(value)) ?? Data() }

struct EditorShell<Content: View>: View {
    let title: String
    var saveTitle = "保存"
    var height: CGFloat = 720
    var startsDirty = false
    var saveValidation: () -> Bool = { true }
    var draftChanged: () -> Void = {}
    var flushDraft: () -> Void = {}
    var discardDraft: () -> Void = {}
    var draftStatus: String? = nil
    var keepDraft: (() -> Bool)? = nil
    var snapshot: () -> Data
    var save: () throws -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @LocalState private var error: String?
    @LocalState private var baseline: Data?
    @LocalState private var owner = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.title3.weight(.semibold)); Spacer() }.padding(.horizontal, 22).padding(.vertical, 18)
            Divider()
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if let error { Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 12).accessibilityIdentifier("editorError") }
            HStack { if let draftStatus { Text(draftStatus).font(.caption).foregroundStyle(.secondary) }; if let keepDraft { Button("存为草稿") { if keepDraft() { EditorProtection.shared.clear(owner: owner); dismiss() } }.buttonStyle(.plain) }; Spacer(); Button("取消", action: close).keyboardShortcut(.cancelAction); Button(saveTitle) { guard saveValidation() else { self.error = nil; return }; do { try save(); EditorProtection.shared.clear(owner: owner); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }.padding(20)
        }.frame(width: 600, height: min(height, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
            .interactiveDismissDisabled(true)
            .onAppear { if baseline == nil { baseline = snapshot() }; register(); draftChanged() }
            .onChange(of: snapshot()) { _, _ in register(); draftChanged() }
            .onDisappear { EditorProtection.shared.clear(owner: owner) }
    }
    private func register() { EditorProtection.shared.update(owner: owner, dirty: { startsDirty || (baseline.map { $0 != snapshot() } ?? false) }, save: { guard saveValidation() else { throw WorkspaceError("请补全标出的必填信息。") }; try save() }, reportError: { error = $0 }, discard: discardDraft, checkpoint: flushDraft) }
    private func close() { register(); if EditorProtection.shared.resolve() { dismiss() } }
}

struct ProjectEditor: View {
    var store: AppStore
    @LocalState private var item: Project
    init(store: AppStore, initial: Project) {
        self.store = store
        var value = initial
        if store.workspace.project(value.id) == nil { value.color = store.workspace.availableRouteColor() }
        if value.status == .completed && value.closedAt == nil { value.closedAt = Date() }
        if value.status == .archived && value.archivedAt == nil { value.archivedAt = Date() }
        _item = State(initialValue: value)
    }
    var body: some View {
        EditorShell(title: store.workspace.project(item.id) == nil ? "新建项目" : "编辑项目", snapshot: { editorSnapshot(item) }, save: { item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines); try store.saveProject(item) }) {
            Form {
                Section("项目信息") { TextField("名称", text: $item.title).accessibilityIdentifier("projectTitle"); TextField("说明", text: $item.note, axis: .vertical).lineLimit(3...6) }
                Section("组织") {
                    Picker("状态", selection: $item.status) { ForEach(WorkStatus.allCases, id: \.self) { Text($0.title).tag($0) } }
                    ColorPickerRow(selection: $item.color, occupied: store.workspace.occupiedRouteColors(excluding: item.id))
                    DatePicker("起始日期", selection: $item.createdAt, displayedComponents: .date)
                    if item.status == .completed || item.closedAt != nil { DatePicker("结束日期", selection: Binding(get: { item.closedAt ?? Date() }, set: { item.closedAt = $0 }), displayedComponents: .date) }
                    if item.status == .archived { DatePicker("归档日期", selection: Binding(get: { item.archivedAt ?? Date() }, set: { item.archivedAt = $0 }), displayedComponents: .date) }
                    if let latest = store.workspace.merges.filter({ $0.projectID == item.id }).map(\.date).max() { Text("结束 / 归档不得早于最近合并：\(fullDate(latest))").font(.caption).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped)
                .onChange(of: item.status) { _, status in
                    if status == .completed { item.closedAt = item.closedAt ?? Date(); item.archivedAt = nil }
                    else if status == .archived { item.archivedAt = item.archivedAt ?? Date() }
                    else { item.closedAt = nil; item.archivedAt = nil }
                    if status != .archived && store.workspace.occupiedRouteColors(excluding: item.id).contains(item.color) { item.color = store.workspace.availableRouteColor(excluding: item.id) }
                }
        }
    }
}

struct ColorPickerRow: View {
    @Binding var selection: Int
    var occupied: Set<Int>
    @LocalState private var showingPalette = false
    var body: some View {
        HStack(spacing: 10) {
            Text("识别色")
            Spacer()
            Circle().fill(projectColor(selection)).frame(width: 20, height: 20)
            Button("色板") { showingPalette = true }
                .popover(isPresented: $showingPalette, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("选择识别色").font(.headline)
                        Text("✓ 当前颜色　× 已占用").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 7), count: 8), spacing: 7) {
                            ForEach(RouteColors.swatchIDs, id: \.self) { id in
                                let unavailable = occupied.contains(id) && id != selection
                                Button {
                                    selection = id; showingPalette = false
                                } label: {
                                    RoundedRectangle(cornerRadius: 5).fill(projectColor(id))
                                        .frame(width: 26, height: 26)
                                        .overlay {
                                            if id == selection || unavailable {
                                                Image(systemName: id == selection ? "checkmark" : "xmark")
                                                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                                    .shadow(color: .black.opacity(0.7), radius: 1)
                                            }
                                        }
                                        .opacity(unavailable ? 0.4 : 1)
                                }.buttonStyle(.plain).disabled(unavailable)
                                    .help("\(RouteColors.swatchName(id))\(unavailable ? " · 已被其他项目或分支占用" : id == selection ? " · 当前颜色" : "")")
                                    .accessibilityLabel("\(RouteColors.swatchName(id))\(unavailable ? "，已占用" : id == selection ? "，当前颜色" : "")")
                            }
                        }
                    }.padding(16).frame(width: 289)
                }
            Button("换一个") { selection = RouteColors.choose(excluding: occupied.union([selection])) }
        }
    }
}

struct ProjectChecks: View {
    let projects: [Project]
    @Binding var selection: [UUID]
    var locked: Set<UUID> = []
    var body: some View {
        if projects.isEmpty { Text("尚无项目。分支可以先独立存在，之后再关联项目。").foregroundStyle(.secondary) }
        ForEach(projects) { project in
            Toggle(isOn: Binding(get: { selection.contains(project.id) }, set: { yes in if yes { if !selection.contains(project.id) { selection.append(project.id) } } else { selection.removeAll { $0 == project.id } } })) { Label(project.title, systemImage: "folder").foregroundStyle(projectColor(project.color)) }.toggleStyle(.checkbox).disabled(locked.contains(project.id))
            if locked.contains(project.id) { Text("已有成果合并至此项目，需先处理对应合并成果才能解除关联。").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct BranchEditor: View {
    var store: AppStore
    @LocalState private var item: Branch
    init(store: AppStore, initial: Branch) {
        self.store = store
        var value = initial
        if store.workspace.branch(value.id) == nil { value.color = store.workspace.availableRouteColor() }
        if value.status == .completed && value.closedAt == nil { value.closedAt = Date() }
        if value.status == .archived && value.archivedAt == nil { value.archivedAt = Date() }
        _item = State(initialValue: value)
    }
    var body: some View {
        EditorShell(title: store.workspace.branch(item.id) == nil ? "新建分支" : "编辑分支", snapshot: { editorSnapshot(item) }, save: { try store.saveBranch(item) }) {
            Form {
                Section("分支信息") { TextField("名称", text: $item.title); TextField("说明", text: $item.note, axis: .vertical).lineLimit(2...5); ColorPickerRow(selection: $item.color, occupied: store.workspace.occupiedRouteColors(excluding: item.id)) }
                Section("关联项目 · 可多选") { ProjectChecks(projects: store.workspace.projects, selection: $item.projectIDs, locked: store.workspace.lockedProjectIDs(for: item.id)) }
                Section("时间与状态") {
                    Picker("分叉起点", selection: Binding<UUID?>(get: { item.originBranchID ?? item.originProjectID }, set: { id in
                        if let parent = store.workspace.branch(id) { item.originBranchID = parent.id; item.originProjectID = nil }
                        else { item.originProjectID = id; item.originBranchID = nil }
                    })) {
                        Text("独立起点").tag(nil as UUID?)
                        ForEach(store.workspace.projects.filter { item.projectIDs.contains($0.id) }) { Text($0.title + " · 主干").tag(Optional($0.id)) }
                        ForEach(store.workspace.branches.filter { $0.id != item.id && !store.workspace.branchAncestors($0.id).contains(item.id) }) { Text($0.title + " · 分支").tag(Optional($0.id)) }
                    }.disabled(store.workspace.merges.contains { $0.branchID == item.id && $0.targetBranchID != nil })
                    if store.workspace.merges.contains(where: { $0.branchID == item.id && $0.targetBranchID != nil }) { Text("已有成果合并回父分支，需先处理对应合并成果才能更改分叉起点。").font(.caption).foregroundStyle(.secondary) }
                    DatePicker("开始日期", selection: $item.startAt, displayedComponents: .date)
                    Picker("状态", selection: $item.status) { ForEach(WorkStatus.allCases, id: \.self) { Text($0.title).tag($0) } }
                    if item.status == .completed || item.closedAt != nil { DatePicker("结束日期", selection: Binding(get: { item.closedAt ?? Date() }, set: { item.closedAt = $0 }), displayedComponents: .date) }
                }
                Section {
                    if item.status == .archived { DatePicker("归档日期", selection: Binding(get: { item.archivedAt ?? Date() }, set: { item.archivedAt = $0 }), displayedComponents: .date) }
                    if let latest = store.workspace.merges.filter({ $0.branchID == item.id || $0.targetBranchID == item.id }).map(\.date).max() { Text("结束 / 归档不得早于最近合并：\(fullDate(latest))").font(.caption).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped)
                .onChange(of: item.projectIDs) { _, ids in if let origin = item.originProjectID, !ids.contains(origin) { item.originProjectID = nil } }
                .onChange(of: item.status) { _, status in
                    if status == .completed { item.closedAt = item.closedAt ?? Date(); item.archivedAt = nil }
                    else if status == .archived { item.archivedAt = item.archivedAt ?? Date() }
                    else { item.closedAt = nil; item.archivedAt = nil }
                    if status != .archived && store.workspace.occupiedRouteColors(excluding: item.id).contains(item.color) { item.color = store.workspace.availableRouteColor(excluding: item.id) }
                }
        }
    }
}

struct RecordEditor: View {
    var store: AppStore
    var recurrence: RecurringEdit?
    var startsDirty = false
    @LocalState private var item: WorkRecord
    @LocalState private var showingReminders: Bool
    @LocalState private var showingDetails: Bool
    @LocalState private var showingMore: Bool
    @LocalState private var showingMaterials: Bool
    @LocalState private var locationAttempted = false
    @LocalState private var locationFocusRequest = 0
    @LocalState private var titleAttempted = false
    @LocalState private var taskScope: RecurrenceScope = .occurrence
    @LocalState private var didCommit = false
    @LocalState private var writeToCalendar = UserDefaults.standard.bool(forKey: "calendar.writeNewMeetings")
    private let original: WorkRecord?
    private let initialValue: WorkRecord
    private let draftKey: String
    private let restoredCopy: Bool
    @FocusState private var titleFocused: Bool
    init(store: AppStore, initial: WorkRecord, recurrence: RecurringEdit? = nil, startsDirty: Bool = false, draft: RecordDraft? = nil) {
        self.store = store
        let conflict = draft?.conflicts(in: store.workspace) == true
        self.restoredCopy = conflict
        self.recurrence = conflict ? nil : recurrence
        self.startsDirty = startsDirty || draft != nil
        self.original = draft != nil ? (conflict ? nil : draft?.original) : store.workspace.record(recurrence?.seriesID ?? initial.id)
        self.draftKey = draft?.id ?? RecordDraft.key(initial.id, recurrence: recurrence?.draftValue)
        var value = initial
        if conflict { value.id = UUID(); value.seriesID = nil; value.originalOccurrence = nil; value.taskSeriesID = nil; value.taskOccurrence = nil; value.taskRepeatRule = nil; value.taskRepeatUntil = nil; value.createdAt = Date(); value.updatedAt = Date() }
        if self.recurrence?.scope == .occurrence { value.repeatRule = .none; value.repeatUntil = nil; value.recurrenceAnchor = nil; value.excludedOccurrences = nil }
        _taskScope = State(initialValue: conflict ? .occurrence : draft?.taskScope ?? .occurrence)
        self.initialValue = value
        _item = State(initialValue: value); _showingReminders = State(initialValue: initial.hasReminders)
        _showingDetails = State(initialValue: !initial.body.isEmpty)
        _showingMaterials = State(initialValue: !(initial.materials ?? []).isEmpty)
        _showingMore = State(initialValue: initial.hasReminders || !initial.dateOnly)
    }
    private var components: DatePickerComponents { item.dateOnly ? .date : [.date, .hourAndMinute] }
    var body: some View {
        EditorShell(title: recurrence.map { "编辑会议 · \($0.scope.rawValue)" } ?? (store.workspace.record(item.id) == nil ? "新增记录" : "编辑记录"), saveTitle: recordSaveTitle, height: item.kind == .progress ? (showingMore || showingMaterials ? 720 : showingDetails ? 540 : 430) : 720, startsDirty: startsDirty, saveValidation: validateRequiredFields, draftChanged: persistDraft, flushDraft: { store.flushDrafts() }, discardDraft: { store.removeDraft(draftKey) }, draftStatus: store.draftStatus(draftKey), keepDraft: !store.isDemo && store.recordDrafts.contains(where: { $0.id == draftKey }) ? { persistDraft(); store.flushDrafts(); return store.draftError == nil } : nil, snapshot: { editorSnapshot(item) + Data(taskScope.rawValue.utf8) }, save: {
            if item.kind == .progress {
                item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.title.isEmpty else { throw WorkspaceError("请先写下一条进展。") }
            }
            try store.saveRecord(item, recurrence: recurrence, taskScope: taskScope)
            didCommit = true; store.removeDraft(draftKey)
            if writeToCalendar && recurrence == nil && item.calendarLink == nil && item.canWriteToCalendar && !store.isDemo && store.calendarService.writeTarget != nil {
                store.writeMeetingToCalendar(item.id)
            }
        }) {
            VStack(spacing: 0) {
                if let id = item.taskSeriesID, store.workspace.taskPlans?.first(where: { $0.id == id })?.active == true {
                    HStack {
                        Picker("修改范围", selection: $taskScope) { Text("仅本次").tag(RecurrenceScope.occurrence); Text("本次及以后").tag(RecurrenceScope.following) }.pickerStyle(.segmented)
                    }.padding(.horizontal, 22).padding(.vertical, 14)
                    Divider()
                }
                Form {
                if restoredCopy { Text("原记录已变化，草稿将另存为新记录。").font(.callout).foregroundStyle(.secondary) }
                if item.kind == .progress && recurrence == nil {
                    compactProgressFields
                } else {
                if let recurrence {
                    Section("修改范围") {
                        Text(recurrence.scope == .series ? "修改当前系列；已单独修改的例外保留自定义内容与时间。" : "所选会议：" + WorkDateText.date(recurrence.occurrence, timed: true, zone: item.timeZoneID))
                        if recurrence.scope == .following { Text("此处及以后拆分为新系列；之前的历史保留。已有单次例外保留自定义内容与时间。").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("记录内容") {
                    Picker("类型", selection: $item.kind) { ForEach(RecordKind.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).disabled(recurrence != nil || item.seriesID != nil || item.taskSeriesID != nil)
                    TextField("标题（必填）", text: $item.title).focused($titleFocused).accessibilityIdentifier("recordTitle")
                    if titleAttempted && item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("请填写记录内容").font(.caption).foregroundStyle(.red) }
                    TextField("文字记录", text: $item.body, axis: .vertical).lineLimit(4...10).accessibilityIdentifier("recordBody")
                }
                Section("归属") {
                    RecordingLocationPicker(store: store, selection: progressLocation, required: true, focusRequest: locationFocusRequest, attempted: locationAttempted)
                }
                materialFields
                timeFields
                if item.kind != .progress { statusFields }
                if item.kind == .task {
                    TaskRepeatFields(store: store, item: $item, scope: $taskScope)
                    DisclosureGroup("等待其他任务完成") {
                        let tasks = store.workspace.records.filter { $0.kind == .task && $0.id != item.id }
                        if tasks.isEmpty { Text("暂无其他任务").foregroundStyle(.secondary) }
                        ForEach(tasks) { task in
                            Toggle(isOn: Binding(get: { item.dependencies.contains(task.id) }, set: { yes in if yes { item.dependencies.append(task.id) } else { item.dependencies.removeAll { $0 == task.id } } })) { Text(task.title).lineLimit(2) }.toggleStyle(.checkbox)
                        }
                    }
                }
                DisclosureGroup("提醒 · \(item.hasReminders ? "已设置" : "默认不添加")", isExpanded: $showingReminders) { reminderFields }
                }
            }.formStyle(.grouped)
                .environment(\.timeZone, TimeZone(identifier: item.timeZoneID) ?? .current)
                .onChange(of: item.kind) { _, kind in
                    if kind == .meeting { item.dateOnly = false; item.endAt = item.endAt ?? item.startAt.addingTimeInterval(3600) }
                    if kind != .meeting { item.repeatRule = .none }
                    if kind != .task { item.dependencies = []; item.dueAt = nil }
                    if kind == .task { if item.taskScheduled == nil { item.taskScheduled = false }; if !item.hasPlannedStart { item.endAt = nil } }
                    if kind == .progress { item.endAt = nil; item.status = .active; item.completedAt = nil }
                    cleanRelativeRules()
                }
                .onChange(of: item.availableReminderRules) { _, _ in cleanRelativeRules() }
                .onChange(of: item.status) { _, status in item.completedAt = status == .completed ? Date() : nil }
            }
        }
    }
    private var recordSaveTitle: String {
        if item.taskSeriesID != nil { return taskScope == .following ? "保存本次及以后" : "保存本次" }
        if let recurrence { return recurrence.scope == .series ? "保存整个系列" : recurrence.scope == .following ? "保存本次及以后" : "保存本次" }
        return "保存"
    }
    private func persistDraft() {
        guard !didCommit else { return }
        store.checkpointDraft(item, original: original, recurrence: recurrence, dirty: startsDirty || item != initialValue || taskScope != .occurrence, key: draftKey, taskScope: item.taskSeriesID == nil ? nil : taskScope)
    }
    private func validateRequiredFields() -> Bool {
        if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { titleAttempted = true; titleFocused = true; return false }
        guard let location = item.recordingLocation, location.exists(in: store.workspace) else {
            locationAttempted = true; locationFocusRequest += 1; return false
        }
        return true
    }
    private var progressLocation: Binding<RecordingLocation?> {
        Binding(get: { item.recordingLocation }, set: { location in
            if let location { item = location.applying(to: item) }
            else { item.branchID = nil; item.projectIDs = [] }
        })
    }
    @ViewBuilder private var compactProgressFields: some View {
        Section {
            HStack(alignment: .top, spacing: 16) { RecordingLocationPicker(store: store, selection: progressLocation, required: true, focusRequest: locationFocusRequest, attempted: locationAttempted); Spacer(minLength: 0); ProgressDateButton(record: $item) }
        }
        Section {
            TextField("进展", text: $item.title, prompt: Text("记下一条进展…")).labelsHidden().focused($titleFocused).accessibilityIdentifier("recordTitle")
            if titleAttempted && item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("请写下一条进展").font(.caption).foregroundStyle(.red) }
            DisclosureGroup("添加详细说明", isExpanded: $showingDetails) {
                TextField("详细说明", text: $item.body, prompt: Text("详细说明"), axis: .vertical).lineLimit(4...10).accessibilityIdentifier("recordBody")
            }
        }
        materialFields
        DisclosureGroup("更多设置", isExpanded: $showingMore) {
            Picker("记录类型", selection: $item.kind) { ForEach(RecordKind.allCases, id: \.self) { Text($0.title).tag($0) } }
            Toggle("只记录日期", isOn: $item.dateOnly)
            if !item.dateOnly { DatePicker("发生时间", selection: $item.startAt, displayedComponents: [.date, .hourAndMinute]) }
            if item.timeZoneID != TimeZone.current.identifier { Text("时区：\(item.timeZoneID)").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("提醒 · \(item.hasReminders ? "已设置" : "默认不添加")", isExpanded: $showingReminders) { reminderFields }
        }
    }
    @ViewBuilder private var calendarRow: some View {
        if let link = item.calendarLink {
            LabeledContent("Apple 日历", value: link.calendarTitle).help("已关联。在脉络里修改后会自动写回日历。")
        } else {
            Toggle("同步到电脑日历", isOn: $writeToCalendar)
                .disabled(!item.canWriteToCalendar || store.calendarService.writeTarget == nil)
                .help(store.calendarService.writeTarget.map { "保存后写入「\($0.title)」，之后的修改自动写回。" } ?? "")
            if store.calendarService.writeTarget == nil { Text("先在 设置 › 日历 中选择写入的日历。").font(.caption).foregroundStyle(.secondary) }
            else if !item.canWriteToCalendar { Text("重复会议暂不能写入日历。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var materialFields: some View {
        DisclosureGroup(isExpanded: $showingMaterials) {
            MaterialLinkFields(store: store, links: $item.materials)
        } label: {
            Text((item.materials?.count ?? 0) > 0 ? "相关资料 · \(item.materials?.count ?? 0)" : "相关资料")
        }
    }
    private var timeFields: some View {
        Section("时间") {
            if item.kind == .progress {
                DatePicker("发生日期", selection: $item.startAt, displayedComponents: components)
                DisclosureGroup("时间细节") { Toggle("只记录日期", isOn: $item.dateOnly); if item.timeZoneID != TimeZone.current.identifier { Text("时区：\(item.timeZoneID)").font(.caption).foregroundStyle(.secondary) } }
            } else {
                if item.kind == .task {
                    Toggle("安排计划日期", isOn: Binding(get: { item.hasPlannedStart }, set: { item.taskScheduled = $0; if !$0 { item.endAt = nil }; cleanRelativeRules() }))
                }
                if item.kind == .meeting || item.hasPlannedStart {
                    if item.kind == .task { Toggle("只记录日期", isOn: $item.dateOnly) }
                    DatePicker(item.kind == .meeting ? "开始时间" : "计划开始", selection: $item.startAt, displayedComponents: components)
                    if item.kind == .task { Toggle("设置计划结束", isOn: Binding(get: { item.endAt != nil }, set: { item.endAt = $0 ? item.startAt.addingTimeInterval(3600) : nil })) }
                    if item.endAt != nil { DatePicker(item.kind == .meeting ? "结束时间" : "计划结束", selection: Binding(get: { item.endAt ?? item.startAt }, set: { item.endAt = $0 }), displayedComponents: components) }
                }
                if item.kind == .task {
                    Toggle("设置 DDL", isOn: Binding(get: { item.dueAt != nil }, set: { item.dueAt = $0 ? Calendar.current.date(byAdding: .day, value: 1, to: item.startAt) : nil; cleanRelativeRules() }))
                    if item.dueAt != nil {
                        Toggle("DDL 仅日期", isOn: $item.dueDateOnly)
                        DatePicker("截止时间", selection: Binding(get: { item.dueAt ?? item.startAt }, set: { item.dueAt = $0 }), displayedComponents: item.dueDateOnly ? .date : [.date, .hourAndMinute])
                    }
                }
                if item.kind == .meeting { Picker("重复", selection: $item.repeatRule) { ForEach(RepeatRule.allCases, id: \.self) { Text($0.title).tag($0) } }.disabled(recurrence?.scope == .occurrence || item.seriesID != nil).help("取消重复时，已有单次例外会保留为独立会议。"); if !store.isDemo { calendarRow } }
                if item.timeZoneID != TimeZone.current.identifier { Text("时区：\(item.timeZoneID)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var statusFields: some View {
        Section(item.taskSeriesID == nil ? "状态" : "本次状态") {
            Picker("状态", selection: $item.status) { ForEach(WorkStatus.allCases, id: \.self) { Text($0.title).tag($0) } }
            if item.status == .completed { DatePicker("实际完成", selection: Binding(get: { item.completedAt ?? Date() }, set: { item.completedAt = $0 }), displayedComponents: [.date, .hourAndMinute]) }
        }
    }
    private var reminderFields: some View {
        Group {
            ForEach(item.availableReminderRules, id: \.self) { rule in
                Toggle(rule.title, isOn: Binding(get: { item.relativeRules.contains(rule) }, set: { enabled in
                    var rules = item.relativeRules; if enabled { rules.append(rule) } else { rules.removeAll { $0 == rule } }; item.relativeReminders = rules
                })).toggleStyle(.checkbox)
            }
            ForEach(Array(item.reminderDates.enumerated()), id: \.offset) { index, _ in
                HStack {
                    DatePicker("固定提醒 \(index + 1)", selection: Binding(get: { item.reminderDates[index] }, set: { item.reminderDates[index] = $0 }), displayedComponents: [.date, .hourAndMinute])
                    Button { item.reminderDates.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("移除固定提醒 \(index + 1)")
                }
            }
            Button("添加固定时间提醒") { item.reminderDates.append(Date().addingTimeInterval(3600)) }
            if item.repeatRule != .none && !item.reminderDates.isEmpty { Text("固定提醒按自身时间重复；要跟随每次会议，请用相对提醒。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func cleanRelativeRules() { if item.relativeReminders != nil { item.relativeReminders = item.relativeRules.filter { item.availableReminderRules.contains($0) } } }
}

struct MergeEditor: View {
    var store: AppStore
    let branchID: UUID
    @LocalState private var target: UUID?
    @LocalState private var date = Date()
    @LocalState private var summary = ""
    @LocalState private var closes = false
    @LocalState private var sourceIDs: Set<UUID> = []
    init(store: AppStore, branchID: UUID) {
        self.store = store; self.branchID = branchID
        _target = State(initialValue: store.workspace.branch(branchID)?.originBranchID ?? store.workspace.branch(branchID)?.projectIDs.first)
    }
    private var snapshot: Data { editorSnapshot(MergeDraft(target: target, date: date, summary: summary, closes: closes, sources: sourceIDs.sorted { $0.uuidString < $1.uuidString })) }
    private struct MergeDraft: Encodable { var target: UUID?; var date: Date; var summary: String; var closes: Bool; var sources: [UUID] }
    var branch: Branch? { store.workspace.branch(branchID) }
    var body: some View {
        EditorShell(title: "合并阶段成果", saveTitle: "合并", snapshot: { snapshot }, save: {
            guard let target else { throw WorkspaceError("请选择父分支或关联项目。") }
            var merge: MergeRecord
            if target == branch?.originBranchID { merge = MergeRecord(branchID: branchID, targetBranchID: target, summary: summary, sourceRecordIDs: Array(sourceIDs)) }
            else { merge = MergeRecord(branchID: branchID, projectID: target, summary: summary, sourceRecordIDs: Array(sourceIDs)) }
            merge.date = date; merge.closesBranch = closes
            try store.saveMerge(merge)
        }) {
            Form {
                Section("合并关系") {
                    LabeledContent("来源分支", value: branch?.title ?? "")
                    Picker("合并目标", selection: $target) {
                        Text("选择目标").tag(nil as UUID?)
                        if let parent = store.workspace.branch(branch?.originBranchID) { Text(parent.title + " · 父分支").tag(Optional(parent.id)) }
                        ForEach(store.workspace.projects.filter { branch?.projectIDs.contains($0.id) == true }) { Text($0.title + " · 项目主干").tag(Optional($0.id)) }
                    }
                    DatePicker("合并时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
                Section("当次成果摘要") { TextField("这次成果为项目带来了什么？", text: $summary, axis: .vertical).lineLimit(5...10) }
                Section("引用记录") {
                    let records = store.workspace.records.filter { $0.branchID == branchID && $0.startAt <= date }.sorted { $0.startAt < $1.startAt }
                    if records.isEmpty { Text("暂无可引用记录，也可以直接写摘要。").foregroundStyle(.secondary) }
                    ForEach(records) { record in Toggle(isOn: Binding(get: { sourceIDs.contains(record.id) }, set: { if $0 { sourceIDs.insert(record.id) } else { sourceIDs.remove(record.id) } })) { Text("\(shortDate(record.startAt))  \(record.title)") }.toggleStyle(.checkbox) }
                }
                Section {
                    Toggle("合并后结束这条分支", isOn: $closes)
                    Text(closes ? "结束将影响这条共享分支在所有项目中的状态；各项目已有合并记录保持独立。" : "分支会继续存在，可更新进度并再次向不同项目合并成果。").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}
