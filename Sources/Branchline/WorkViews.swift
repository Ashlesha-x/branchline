import SwiftUI
import ProgressCore

struct SearchResultsView: View {
    @Bindable var store: AppStore
    private var hits: [SearchHit] { store.searchHits.filter { store.searchEntityFilter == nil || $0.kind == store.searchEntityFilter } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                filterButton(nil, title: "全部", count: store.searchHits.count)
                ForEach(SearchEntity.allCases, id: \.self) { kind in filterButton(kind, title: kind.title, count: store.searchHits.filter { $0.kind == kind }.count) }
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            ActiveRecordFilters(store: store)
            Divider()
            if hits.isEmpty {
                ContentUnavailableView("无匹配结果", systemImage: "magnifyingglass", description: Text(store.searchEntityFilter == nil ? "请更换关键词，或切换到全部项目。" : "此分类暂无匹配内容，可选择其他分类。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(hits, id: \.id.uuidString) { hit in
                            HStack(alignment: .center, spacing: 12) {
                                Button { store.showSearchHit(hit) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(hit.kind.title).font(.caption).foregroundStyle(.secondary).frame(width: 30)
                                        VStack(alignment: .leading, spacing: 5) {
                                            highlighted(hit.title).fontWeight(.medium).lineLimit(2)
                                            if !hit.detail.isEmpty { highlighted(hit.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                                        }
                                        Spacer(minLength: 5)
                                        Text(shortDate(hit.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("搜索结果：\(hit.kind.title)，\(hit.title)")
                                Button { store.showSearchHit(hit, inContext: true) } label: { Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary) }.buttonStyle(.plain).help("在路线中查看位置").accessibilityLabel("查看位置：\(hit.title)")
                            }.padding(16).background(store.selectedEntityID == hit.id ? Color.accentColor.opacity(0.08) : .clear).id(hit.id.uuidString)
                            Divider().padding(.leading, 58)
                        }
                    }.scrollTargetLayout()
                }.rememberingBrowsePosition(store, surface: "search")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
            .onChange(of: Set(hits.map(\.id)), initial: true) { _, ids in closeFilteredDetail(ids) }
            .onChange(of: store.selection) { _, _ in closeFilteredDetail(Set(hits.map(\.id))) }
    }
    private func closeFilteredDetail(_ ids: Set<UUID>) {
        guard store.isSearching, !store.showingUtilityPage, !store.showingReview else { return }
        if let id = store.selectedEntityID, !ids.contains(id) { store.selection = nil }
    }
    private func filterButton(_ kind: SearchEntity?, title: String, count: Int) -> some View {
        Button { store.browse { store.searchEntityFilter = kind; store.viewportOffsets["search"] = BrowseOffset(); store.browseRestoreToken = UUID() } } label: {
            Text("\(title) \(count)").font(.callout.weight(store.searchEntityFilter == kind ? .semibold : .regular)).padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(store.searchEntityFilter == kind ? Color.primary : Color.secondary)
                .background(store.searchEntityFilter == kind ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel("筛选\(title)，\(count) 项")
    }
    private func highlighted(_ value: String) -> Text {
        let query = store.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(value) }
        var remaining = value[...], result = Text("")
        while let range = remaining.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            guard !range.isEmpty else { break }
            result = result + Text(remaining[..<range.lowerBound]) + Text(remaining[range]).bold().foregroundColor(.primary)
            remaining = remaining[range.upperBound...]
        }
        return result + Text(remaining)
    }
}

struct AgendaView: View {
    @Bindable var store: AppStore
    private var scope: AgendaScope { store.agendaScope }
    @LocalState private var blockedTaskID: UUID?
    @LocalState private var now = Date()
    var items: [AgendaItem] { store.workspace.agenda(scope, now: now) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(AgendaScope.allCases, id: \.self) { category in
                        Button { store.changeAgendaScope(category) } label: {
                            Text("\(category.rawValue) \(store.workspace.agenda(category, now: now).count)")
                                .font(.callout).padding(.horizontal, 10).padding(.vertical, 7)
                                .background(scope == category ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).help(scopeHelp(category))
                    }
                }.padding(14)
            }.scrollIndicators(.hidden)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if items.isEmpty { ContentUnavailableView("暂无\(scope.rawValue)事项", systemImage: "checkmark.circle", description: Text("可从项目或分支旁的 ＋ 添加任务和会议。")).frame(minHeight: 220) }
                    ForEach(items) { item in agendaRow(item).id(item.id) }
                }.scrollTargetLayout()
            }.rememberingBrowsePosition(store, surface: "agenda")
        }.onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = Date() }
    }
    private func scopeHelp(_ category: AgendaScope) -> String { category == .week ? "包含今天在内的七个日历日；会议按每次发生时间展示。" : category == .today ? "今天的会议、截止任务及计划日期覆盖今天的进行中任务。" : category == .blocked ? "这些任务仍有未完成的依赖，可点开详情处理。" : category == .unscheduled ? "未设置计划开始、计划结束和截止日期的任务。" : "截止时间已过且仍在进行中的任务。" }
    private func agendaRow(_ item: AgendaItem) -> some View {
        let record = item.record
        let projects = store.workspace.projects(for: record).compactMap { store.workspace.project($0)?.title }.joined(separator: "、")
        return HStack(alignment: .top, spacing: 12) {
            if record.kind == .task {
                Button {
                    if store.workspace.blockedBy(record).isEmpty { store.completeAgendaTask(record.id) }
                    else { blockedTaskID = record.id }
                } label: { Image(systemName: "circle").font(.title3).foregroundStyle(.secondary).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("标记完成").accessibilityLabel("标记完成：\(record.title)")
                    .popover(isPresented: Binding(get: { blockedTaskID == record.id }, set: { if !$0 { blockedTaskID = nil } })) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("请先完成以下依赖").fontWeight(.medium)
                            ForEach(store.workspace.blockedBy(store.workspace.record(record.id) ?? record)) { dependency in
                                Button(dependency.title) { blockedTaskID = nil; store.browse { store.selection = .record(dependency.id); store.selectedOccurrence = nil; store.moveTo(dependency.startAt) } }
                            }
                        }.padding(18).frame(minWidth: 240, maxWidth: 340)
                    }
            }
            if record.kind != .task { Image(systemName: record.kind.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24, height: 24) }
            Button { store.browse { store.selection = .record(record.id); store.selectedOccurrence = record.kind == .meeting ? item.date : nil; store.moveTo(item.date) } } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Text(record.title).fontWeight(.medium)
                        Spacer()
                        if !store.workspace.blockedBy(record).isEmpty { Text("等待依赖").font(.caption).foregroundStyle(.orange) }
                    }
                    if !item.reasons.isEmpty {
                        HStack(spacing: 6) { ForEach(item.reasons, id: \.self) { reason in Text(reason.rawValue).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5)) } }
                    }
                    Text(record.kind == .meeting ? WorkDateText.meetingShort(record, occurrence: item.date) : record.dueAt.map { "截止：" + WorkDateText.short($0, timed: !record.dueDateOnly, zone: record.timeZoneID) } ?? (record.hasPlannedStart ? "计划开始：" + WorkDateText.short(record.startAt, timed: !record.dateOnly, zone: record.timeZoneID) : "未安排日期"))
                        .font(.callout).foregroundStyle(CalendarLogic.deadlinePassed(record, now: now) ? Color.red : .secondary)
                    HStack(spacing: 7) {
                        if let branch = store.workspace.branch(record.branchID) { Text(branch.title) }
                        Text(projects.isEmpty ? "独立分支" : projects)
                        if record.repeatRule != .none { Text("\(record.repeatRule.title)重复") }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if record.kind == .task { deadlineMenu(record) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(store.selection == .record(record.id) ? Color.accentColor.opacity(0.08) : .clear)
            .overlay(alignment: .bottom) { Divider() }
    }
    private func deadlineMenu(_ record: WorkRecord) -> some View {
        Menu {
            Button("截止改为今天") { store.changeDeadline(record.id, to: now) }
            Button("截止改为明天") {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: record.timeZoneID) ?? .current
                if let day = calendar.date(byAdding: .day, value: 1, to: now) { store.changeDeadline(record.id, to: day) }
            }
            Button("选择截止日期…") { store.deadlineEditorID = record.id }
        } label: { Label("改截止", systemImage: "calendar.badge.clock").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("调整截止日期").accessibilityLabel("调整截止日期：\(record.title)")
            .popover(isPresented: Binding(get: { store.deadlineEditorID == record.id }, set: { if !$0 { store.deadlineEditorID = nil } })) {
                DeadlineDatePicker(store: store, record: record)
            }
    }
}

private struct DeadlineDatePicker: View {
    var store: AppStore
    var record: WorkRecord
    @LocalState private var day: Date
    init(store: AppStore, record: WorkRecord) {
        self.store = store; self.record = record; _day = State(initialValue: record.dueAt ?? Date())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("调整截止日期").font(.headline)
            DatePicker("截止日期", selection: $day, displayedComponents: .date)
            if let updated = try? record.withDeadline(on: day), let due = updated.dueAt {
                Text("截止：" + WorkDateText.date(due, timed: !updated.dueDateOnly, zone: updated.timeZoneID)).font(.callout)
            }
            Text("只调整截止日期，不移动计划日期。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { store.deadlineEditorID = nil }
                Spacer()
                Button("应用") { if store.changeDeadline(record.id, to: day) { store.deadlineEditorID = nil } }.buttonStyle(.borderedProminent)
            }
        }.padding(18).frame(width: 310)
            .environment(\.timeZone, TimeZone(identifier: record.timeZoneID) ?? .current)
            .onDisappear { if store.deadlineEditorID == record.id { store.deadlineEditorID = nil } }
    }
}
