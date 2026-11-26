import SwiftUI
import ProgressCore

struct Inspector: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("详情").font(.caption).foregroundStyle(.secondary); Spacer(); Button { store.browse { store.selection = nil } } label: { Image(systemName: "sidebar.right") }.buttonStyle(.plain).help("收起详情").accessibilityLabel("收起详情") }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch store.selection {
                    case .project(let id): if let project = store.workspace.project(id) { projectDetail(project) }
                    case .branch(let id): if let branch = store.workspace.branch(id) { branchDetail(branch) }
                    case .record(let id): if let record = store.workspace.record(id) { recordDetail(record) }
                    case .merge(let id): if let merge = store.workspace.merges.first(where: { $0.id == id }) { mergeDetail(merge) }
                    case nil: EmptyView()
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.rememberingBrowsePosition(store, surface: "inspector")
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private func heading(_ title: String, subtitle: String, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            Text(title).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary); content() }
    }
    private func projectDetail(_ project: Project) -> some View {
        Group {
            heading(project.title, subtitle: "项目主干 · \(project.status.title)", color: projectColor(project.color), symbol: "folder")
            if !project.note.isEmpty { Text(project.note).textSelection(.enabled) }
            section("项目时间") {
                Text("开始于 \(fullDate(project.createdAt))")
                if let end = project.closedAt { Text("结束于 \(fullDate(end))") }
                if let archived = project.archivedAt { Text("归档于 \(fullDate(archived))") }
            }
            section("关联分支") {
                ForEach(store.workspace.branches.filter { $0.projectIDs.contains(project.id) }) { branch in
                    Button { store.browse { store.selection = .branch(branch.id) } } label: { Label(branch.title + (branch.projectIDs.count > 1 ? " · 共享" : ""), systemImage: store.branchSymbol(branch.id)) }.buttonStyle(.plain)
                }
            }
            section("操作") {
                Button("编辑项目") { store.editor = .project(project) }
                Button("拉出新分支") { var branch = Branch(projectIDs: [project.id]); branch.originProjectID = project.id; store.editor = .branch(branch) }
                Button("记录主干进展") { var record = WorkRecord(); record.projectIDs = [project.id]; store.editor = .record(record) }
                Button("删除项目…", role: .destructive) { store.requestDeletion(.project(project.id)) }
            }
            history(project.id)
        }
    }
    private func branchDetail(_ branch: Branch) -> some View {
        Group {
            heading(branch.title, subtitle: "\(store.workspace.branchIsIndependent(branch.id) ? (branch.projectIDs.count > 1 ? "独立分支 · 共享" : "独立分支") : "项目内分支") · \(branch.status.title)", color: projectColor(branch.color), symbol: store.branchSymbol(branch.id))
            if !branch.note.isEmpty { Text(branch.note).textSelection(.enabled) }
            projectLinks(branch.projectIDs)
            section("分支时间") { Text("开始  \(fullDate(branch.startAt))"); Text("结束  \(branch.closedAt.map(fullDate) ?? "未设置")").foregroundStyle(.secondary); if let archived = branch.archivedAt { Text("归档  \(fullDate(archived))") } }
            HStack { Button("编辑") { store.editor = .branch(branch) }; Button("更新进度") { store.newRecord(branchID: branch.id) } }
            Button("合并阶段成果…") { store.editor = .merge(branch.id) }.buttonStyle(.borderedProminent).disabled(branch.projectIDs.isEmpty && branch.originBranchID == nil)
            if branch.projectIDs.isEmpty && branch.originBranchID == nil { Text("先关联项目，即可向主干合并成果。").font(.caption).foregroundStyle(.secondary) }
            Button("拉出子分支") { store.newChildBranch(parentID: branch.id) }
            if let parent = store.workspace.branch(branch.originBranchID) {
                Button("父分支：\(parent.title)") { store.browse { store.selection = .branch(parent.id) } }.buttonStyle(.link)
            }
            mergeLinks(branchID: branch.id)
            Button("删除分支…", role: .destructive) { store.requestDeletion(.branch(branch.id)) }
            history(branch.id)
        }
    }
    private func recordDetail(_ record: WorkRecord) -> some View {
        Group {
            heading(record.title, subtitle: "\(store.workspace.branch(record.branchID)?.title ?? "项目主干") / \(record.kind.title)", color: projectColor(store.workspace.branch(record.branchID)?.color ?? store.workspace.project(record.projectIDs.first)?.color ?? 0), symbol: record.kind.symbol)
            if let link = record.calendarLink { Text("Apple 日历 · " + link.calendarTitle).font(.caption).foregroundStyle(.secondary); if link.disposition == .cancelled { Text("已取消 · 后续提醒已停止").font(.callout).foregroundStyle(.secondary) } }
            if let rule = record.taskRepeatRule, rule != .none { Text("重复任务 · " + rule.title).font(.caption).foregroundStyle(.secondary) }
            Text(record.kind == .meeting ? WorkDateText.meeting(record, occurrence: store.selectedOccurrence) : record.kind == .task && !record.hasPlannedStart ? "计划日期未安排" : WorkDateText.date(record.startAt, timed: !record.dateOnly, zone: record.timeZoneID)).font(.callout).foregroundStyle(.secondary)
            if !record.body.isEmpty { Text(record.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)) }
            if let materials = record.materials, !materials.isEmpty {
                section("相关资料") {
                    ForEach(Array(materials.enumerated()), id: \.offset) { _, link in
                        Button { store.openMaterial(link.url) } label: { Label(link.title, systemImage: link.url.isFileURL ? "doc" : "link") }
                            .buttonStyle(.link).help(link.url.isFileURL ? link.url.path : link.url.absoluteString)
                    }
                }
            }
            projectLinks(store.workspace.projects(for: record))
            if record.kind != .progress {
                section(record.kind == .meeting ? "状态与重复" : "时间与状态") {
                    if record.kind == .meeting {
                        if record.repeatRule != .none { Text("从时间轴或待办点选具体日期后，可操作对应次会议；未点选时使用系列开始日期。").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("计划开始  \(record.hasPlannedStart ? WorkDateText.date(record.startAt, timed: !record.dateOnly, zone: record.timeZoneID) : "未安排")")
                        Text("计划结束  \(record.endAt.map { WorkDateText.date($0, timed: !record.dateOnly, zone: record.timeZoneID) } ?? "未设置")")
                    }
                    if let due = record.dueAt { Text("DDL  \(WorkDateText.date(due, timed: !record.dueDateOnly, zone: record.timeZoneID))").foregroundStyle(CalendarLogic.deadlinePassed(record, now: Date()) ? Color.red : .primary) }
                    Text(record.status.title)
                    if let completed = record.completedAt { Text("实际完成  \(WorkDateText.date(completed, timed: true, zone: record.timeZoneID))").foregroundStyle(.secondary) }
                    if record.repeatRule != .none { Text("\(record.repeatRule.title)重复").foregroundStyle(.secondary) }
                    if let until = record.repeatUntil { Text("重复边界：\(WorkDateText.date(until, timed: true, zone: record.timeZoneID)) 之前").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !record.dependencies.isEmpty {
                section("任务依赖") {
                    ForEach(record.dependencies, id: \.self) { id in if let task = store.workspace.record(id) { Button { store.browse { store.selection = .record(id) } } label: { Label(task.title, systemImage: task.status == .completed ? "checkmark.circle" : "hourglass") }.buttonStyle(.plain).foregroundStyle(task.status == .completed ? Color.secondary : Color.orange) } }
                }
            }
            if record.hasReminders {
                if record.kind == .meeting { meetingReminders(record) }
                else { section("提醒") { ForEach(record.relativeRules, id: \.self) { Text($0.title + " · 随改期更新").font(.callout) }; ForEach(record.reminderDates, id: \.self) { Text("固定：" + WorkDateText.date($0, timed: true, zone: record.timeZoneID)).font(.callout) }; if store.isDemo { Text("示例空间不发送通知").font(.caption).foregroundStyle(.secondary) } } }
            }
            HStack {
                if record.repeatRule != .none {
                    Menu("编辑会议") { ForEach(RecurrenceScope.allCases, id: \.self) { scope in Button(scope.rawValue) { store.editRecurring(record, scope: scope) } } }
                } else { Button("编辑记录") { store.editor = .record(record) } }
                if record.kind == .task && record.status != .completed {
                    Button("标记完成") { var updated = record; updated.status = .completed; updated.completedAt = Date(); do { try store.saveRecord(updated) } catch { store.error = error.localizedDescription } }
                }
            }
            section("录入信息") { Text("录入于 \(WorkDateText.date(record.createdAt, timed: true, zone: record.timeZoneID))"); Text("更新于 \(WorkDateText.date(record.updatedAt, timed: true, zone: record.timeZoneID))") }.font(.caption).foregroundStyle(.secondary)
            history(record.id)
            if record.repeatRule != .none {
                Menu("删除会议…") { ForEach(RecurrenceScope.allCases, id: \.self) { scope in Button(scope.rawValue, role: .destructive) { store.requestRecurringDeletion(record, scope: scope) } } }
            } else { Button("删除记录…", role: .destructive) { store.requestDeletion(.record(record.id)) } }
            if let parent = store.workspace.record(record.seriesID) { Button("查看原重复系列") { store.browse { store.selection = .record(parent.id) } }.buttonStyle(.link) }
        }
    }
    private func meetingReminders(_ record: WorkRecord) -> some View {
        let reminders = record.reminderSchedule(for: store.selectedOccurrence ?? record.startAt)
        return section("本次提醒") {
            if reminders.isEmpty { Text("本次没有提醒").foregroundStyle(.secondary) }
            ForEach(reminders) { reminder in Text(WorkDateText.date(reminder.date, timed: true, zone: record.timeZoneID)).font(.callout) }
            if record.repeatRule != .none { Text("按系列重复").font(.caption).foregroundStyle(.secondary) }
            if !record.relativeRules.isEmpty { Text(record.relativeRules.map(\.title).joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
            Text(store.isDemo ? "示例空间不发送通知" : "按设置计算；实际送达受系统通知权限等影响。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func mergeDetail(_ merge: MergeRecord) -> some View {
        Group {
            heading("阶段成果合并", subtitle: fullDate(merge.date), color: .teal, symbol: "arrow.triangle.merge")
            Text("\(store.workspace.branch(merge.branchID)?.title ?? "分支") → \(store.workspace.mergeTargetTitle(merge))").fontWeight(.medium)
            section("当时的成果摘要") { Text(merge.summary).textSelection(.enabled) }
            Text(merge.closesBranch ? "此次合并后结束分支" : "此次合并后继续分支").font(.caption).foregroundStyle(.secondary)
            section("引用记录 · 查看当前内容") {
                ForEach(merge.sourceRecordIDs, id: \.self) { id in if let record = store.workspace.record(id) { Button(record.title) { store.browse { store.selection = .record(id) } }.buttonStyle(.link) } }
            }
            Text("摘要保留合并时的文字，不随来源记录后续编辑而改变。").font(.caption).foregroundStyle(.secondary)
            Button("查看来源分支") { store.browse { store.selection = .branch(merge.branchID) } }
            Button("删除合并成果…", role: .destructive) { store.requestDeletion(.merge(merge.id)) }
        }
    }
    private func projectLinks(_ ids: [UUID]) -> some View {
        section("关联项目") {
            if ids.isEmpty { Text("独立分支").foregroundStyle(.secondary) }
            ForEach(ids, id: \.self) { id in if let project = store.workspace.project(id) {
                Button { store.browse { store.selection = .project(id) } } label: { Label(project.title, systemImage: "folder.fill").font(.callout).foregroundStyle(projectColor(project.color)) }.buttonStyle(.plain)
            } }
        }
    }
    private func mergeLinks(branchID: UUID) -> some View {
        section("合并记录") {
            let merges = store.workspace.merges.filter { $0.branchID == branchID || $0.targetBranchID == branchID }.sorted { $0.date > $1.date }
            if merges.isEmpty { Text("尚未合并").foregroundStyle(.secondary) }
            ForEach(merges) { merge in Button { store.browse { store.selection = .merge(merge.id) } } label: { Text("\(shortDate(merge.date)) · \(store.workspace.branch(merge.branchID)?.title ?? "分支") → \(store.workspace.mergeTargetTitle(merge))") }.buttonStyle(.plain) }
        }
    }
    private func history(_ id: UUID) -> some View {
        let items = store.workspace.history.filter { $0.entityID == id }.sorted { $0.date > $1.date }
        return Group {
            if !items.isEmpty { section("关键变更") { ForEach(items) { item in VStack(alignment: .leading, spacing: 4) { Text(item.summary); Text(WorkDateText.date(item.date, timed: true)).foregroundStyle(.secondary) }.font(.caption) } } }
        }
    }
}

struct QuickPanel: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @LocalState private var title = ""
    @LocalState private var location: RecordingLocation?
    @LocalState private var kind: RecordKind = .progress
    @LocalState private var feedback = ""
    private var upcoming: [(WorkRecord, Date)] {
        let now = Date()
        return (store.workspace.agenda(.overdue, now: now) + store.workspace.agenda(.week, now: now))
            .filter { $0.record.kind != .meeting || ($0.end ?? $0.date) > now }
            .reduce(into: [(WorkRecord, Date)]()) { result, item in
                if !result.contains(where: { $0.0.id == item.record.id && $0.1 == item.date }) { result.append((item.record, item.date)) }
            }.sorted { $0.1 < $1.1 }.prefix(5).map { $0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("快速记录").font(.headline); Spacer(); if store.isDemo { Text("示例").font(.caption).foregroundStyle(.orange) } }
            Picker("类型", selection: $kind) { ForEach(RecordKind.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 90)
            if kind == .progress {
                if store.editor != nil { Text("主窗口正在编辑，可回到主窗口继续。").font(.callout).foregroundStyle(.secondary) }
                else { QuickProgressComposer(store: store, surface: .menu) }
            } else {
                TextField("记下一项安排…", text: $title).textFieldStyle(.roundedBorder).onSubmit(add)
                HStack {
                    RecordingLocationPicker(store: store, selection: $location)
                    Spacer(minLength: 0)
                    Button("添加", action: add).buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || location?.exists(in: store.workspace) != true)
                }
            }
            if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("近期安排").font(.caption).foregroundStyle(.secondary)
            if upcoming.isEmpty { Text("暂无会议或截止事项").foregroundStyle(.secondary).padding(.vertical, 8) }
            ForEach(Array(upcoming.enumerated()), id: \.offset) { _, pair in
                Button { store.browse { store.selection = .record(pair.0.id); store.selectedOccurrence = pair.0.kind == .meeting ? pair.1 : nil; store.moveTo(pair.1); showMain() } } label: {
                    HStack(alignment: .top) { Text(pair.0.kind == .meeting ? pair.1.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN"))) : shortDate(pair.1)).monospacedDigit().foregroundStyle(.secondary); Text(pair.0.title).lineLimit(2); Spacer(); Image(systemName: pair.0.kind == .meeting ? "calendar" : "flag").foregroundStyle(CalendarLogic.deadlinePassed(pair.0, now: Date()) ? .red : .secondary) }
                }.buttonStyle(.plain)
            }
            Divider()
            HStack { Button("打开主窗口", action: showMain); Spacer(); Button("退出") { EditorProtection.shared.quit() }.buttonStyle(.plain).foregroundStyle(.secondary) }
        }.padding(18).frame(width: 370)
        .onAppear { if title.isEmpty { location = store.lastRecordingLocation }; if kind == .progress { store.beginQuickProgress(.menu) } }
        .onChange(of: kind) { previous, next in
            if previous == .progress && next != .progress {
                if store.quickIsDirty { kind = .progress; feedback = "请先保存当前进展，或从详细编辑更改类型。" }
                else { store.endQuickProgress(); location = store.lastRecordingLocation }
            } else if next == .progress { store.beginQuickProgress(.menu) }
        }
    }
    private func add() {
        var record = WorkRecord(kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let location, location.exists(in: store.workspace) else { feedback = "请先选择有效归属。"; return }
        record = location.applying(to: record)
        if kind == .meeting { record.endAt = Date().addingTimeInterval(3600); store.editor = .record(record); showMain(); return }
        do { try store.saveRecord(record); title = ""; feedback = "已保存，可在主窗口补充详情。" } catch { feedback = error.localizedDescription }
    }
    private func showMain() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
