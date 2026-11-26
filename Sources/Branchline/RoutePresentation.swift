import SwiftUI
import ProgressCore

extension AppStore {
    func branchSymbol(_ id: UUID) -> String {
        workspace.branchIsIndependent(id) ? "point.topleft.down.to.point.bottomright.curvepath" : "arrow.triangle.branch"
    }
    func routeLayout(in scope: CollapseScope) -> [RoutePlacement] {
        let collapsed = collapsedIDs(in: scope)
        let filter = scope == .sidebar ? nil : projectFilter
        let expanded = expandedRouteStatuses(in: scope)
        if let cached = routeLayoutCache[scope], cached.0 == workspaceRevision, cached.1 == filter, cached.2 == collapsed, cached.3 == expanded { return cached.4 }
        let value = workspace.presentedRoutes(projectIDs: workspace.projects.filter { filter == nil || $0.id == filter }.map(\.id), collapsed: collapsed, includeIndependent: filter == nil, rootOrder: routeRootOrder, expandedStatuses: expanded)
        routeLayoutCache[scope] = (workspaceRevision, filter, collapsed, expanded, value)
        return value
    }
    private var detailPreferenceKey: String { "routeDetails.\(isDemo ? "demo" : dataDirectory.path)" }
    private func detailID(_ id: UUID) -> String { "\(projectFilter?.uuidString ?? "all"):\(id)" }
    func restoreRouteDetails() {
        restoreRoutePresentationPreferences()
        for scope in CollapseScope.allCases {
            routeDetailChoices[scope] = (UserDefaults.standard.dictionary(forKey: "\(detailPreferenceKey).\(scope.rawValue)") as? [String: Bool]) ?? [:]
        }
    }
    func routeIsSummary(_ id: UUID, in scope: CollapseScope) -> Bool {
        guard !isSearching else { return false }
        if temporarilyExpandedRoute == id { return false }
        if let expanded = routeDetailChoices[scope]?[detailID(id)] { return !expanded }
        if selectedRouteID == id { return false }
        if let branch = workspace.branch(id) {
            if branch.status == .completed || branch.status == .archived { return true }
            if projectFilter == nil {
                if workspace.branchIsIndependent(branch.id) { return true }
                return !branch.projectIDs.contains { routeDetailChoices[scope]?[detailID($0)] == true }
            }
            return false
        }
        return projectFilter == nil
    }
    func toggleRouteDetails(_ id: UUID, in scope: CollapseScope) {
        let expand = routeIsSummary(id, in: scope)
        temporarilyExpandedRoute = nil
        routeDetailChoices[scope, default: [:]][detailID(id)] = expand
        UserDefaults.standard.set(routeDetailChoices[scope] ?? [:], forKey: "\(detailPreferenceKey).\(scope.rawValue)")
    }
    var selectedRouteID: UUID? {
        switch selection {
        case .project(let id), .branch(let id): return id
        case .record(let id): return workspace.record(id)?.branchID ?? workspace.record(id)?.projectIDs.first { projectFilter == nil || projectFilter == $0 }
        case .merge(let id): return workspace.merges.first { $0.id == id }?.targetLaneID
        case nil: return nil
        }
    }
    var focusedRouteIDs: Set<UUID> {
        if let relation = workspace.routeRelations.first(where: { $0.id == (hoveredRelationID ?? pinnedRelationID) }) { return [relation.source, relation.target] }
        if case .merge(let id) = selection, let relation = workspace.routeRelations.first(where: { $0.entityID == id }) { return [relation.source, relation.target] }
        guard let id = selectedRouteID else { return [] }
        let direct = workspace.routeRelations.filter { $0.source == id || $0.target == id }
        let projectBranches = workspace.project(id) == nil ? [] : workspace.branches.filter { $0.projectIDs.contains(id) }.map(\.id)
        return Set(direct.flatMap { [$0.source, $0.target] }).union([id]).union(workspace.branchAncestors(id)).union(projectBranches)
    }
    func routeOpacity(_ id: UUID) -> Double { focusedRouteIDs.isEmpty ? 0.68 : (focusedRouteIDs.contains(id) ? 1 : 0.42) }
    func routeLineWidth(_ id: UUID, project: Bool) -> CGFloat { focusedRouteIDs.contains(id) ? (project ? 4 : 3) : (project ? 3 : 2.5) }
    func relationExpanded(_ relation: RouteRelation) -> Bool {
        if let current = hoveredRelationID ?? pinnedRelationID { return current == relation.id }
        return selection == .merge(relation.entityID)
    }
    func pinRelation(_ relation: RouteRelation) { pinnedRelationID = pinnedRelationID == relation.id ? nil : relation.id }
    func routeTitle(_ id: UUID) -> String { workspace.project(id)?.title ?? workspace.branch(id)?.title ?? "已移除路线" }
    func visitRelationEndpoint(_ id: UUID) {
        browse {
            let branch = workspace.branch(id)
            if let current = projectFilter, branch?.projectIDs.contains(current) != true && id != current { projectFilter = nil }
            selection = branch == nil ? .project(id) : .branch(id)
            if let branch { moveTo(branch.startAt) }
        }
    }
}

/// Keep the invisible hover target mounted while its label gives way to the curve.
struct RouteRelationMarker: View {
    @Bindable var store: AppStore
    var relations: [RouteRelation]
    var laneID: UUID
    var color: Color
    var width: CGFloat = 110
    var iconOnly = false
    @LocalState private var hoverTask: Task<Void, Never>?
    @LocalState private var showing = false
    private var outgoing: Bool { relations.first?.source == laneID }
    private var caption: String {
        guard let relation = relations.first else { return "" }
        if relations.count > 1 { return "\(relations.count) 处关联" }
        let name = store.routeTitle(outgoing ? relation.target : relation.source)
        if relation.kind == .fork { return outgoing ? "分出 · \(name)" : "源自 · \(name)" }
        return outgoing ? "至 \(name)" : "自 \(name)"
    }
    var body: some View {
        Button {
            if relations.count == 1, let relation = relations.first { store.pinRelation(relation) }
            else { showing.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: outgoing ? "arrow.up.right" : "arrow.down.left").font(.system(size: 9, weight: .medium))
                if !iconOnly && width > 28 { Text(caption).font(.system(size: 9)).lineLimit(1).truncationMode(.tail) }
            }.frame(width: width, height: 20).foregroundStyle(color.opacity(0.8))
                .opacity(relations.contains(where: store.relationExpanded) ? 0 : 1)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(relations.map { "\(store.routeTitle($0.source)) → \(store.routeTitle($0.target)) · \(shortDate($0.date))" }.joined(separator: "\n") + "\n停留查看连线，点击固定；右键可定位两端。")
            .accessibilityLabel(caption + "，关系箭头")
            .onHover { inside in
                hoverTask?.cancel()
                let id = relations.first?.id
                hoverTask = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(inside ? 280 : 180)) } catch { return }
                    if inside { store.hoveredRelationID = id }
                    else if store.hoveredRelationID == id { store.hoveredRelationID = nil }
                }
            }
            .onDisappear { hoverTask?.cancel(); if relations.contains(where: { $0.id == store.hoveredRelationID }) { store.hoveredRelationID = nil } }
            .contextMenu {
                ForEach(relations) { relation in
                    Button("定位来源：\(store.routeTitle(relation.source))") { store.visitRelationEndpoint(relation.source) }
                    Button("定位目标：\(store.routeTitle(relation.target))") { store.visitRelationEndpoint(relation.target) }
                }
            }
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("关联路径").font(.headline)
                    ForEach(relations) { relation in
                        Button { store.pinRelation(relation) } label: {
                            HStack { Text("\(store.routeTitle(relation.source)) → \(store.routeTitle(relation.target))"); Text(shortDate(relation.date)).foregroundStyle(.secondary); if store.pinnedRelationID == relation.id { Image(systemName: "pin.fill") } }.font(.caption)
                        }.buttonStyle(.plain).onHover { store.hoveredRelationID = $0 ? relation.id : nil }
                    }
                }.padding(16).frame(maxWidth: 480)
            }
    }
}

struct RouteSummaryText: View {
    var store: AppStore
    var routeID: UUID
    var now: Date
    @LocalState private var showing: SummaryTasks?
    private enum SummaryTasks: String, Identifiable { case pending, overdue, upcoming; var id: String { rawValue } }
    private var summary: RouteSummary { store.workspace.routeSummary(routeID, now: now) }
    private var tasks: [WorkRecord] { tasks(for: showing) }
    private func tasks(for category: SummaryTasks?) -> [WorkRecord] {
        switch category {
        case .overdue: store.workspace.routeTasks(routeID).filter { CalendarLogic.deadlinePassed($0, now: now) }
        case .upcoming: summary.upcoming
        default: store.workspace.routeTasks(routeID)
        }
    }
    var body: some View {
        HStack(spacing: 18) {
            if summary.pending > 0 { countButton("未完成 \(summary.pending)", type: .pending, warning: false) }
            if summary.overdue > 0 { countButton("逾期 \(summary.overdue)", type: .overdue, warning: true) }
            if !summary.upcoming.isEmpty {
                countButton("7 天内截止 \(summary.upcoming.count)", type: .upcoming, warning: false)
            }
            if summary.pending == 0 {
                if let date = summary.latestUpdate { Text("更新 \(shortDate(date))").foregroundStyle(.secondary) }
                else { Text("暂无记录").foregroundStyle(.secondary) }
            }
        }.font(.system(size: 12)).lineLimit(1)
            .popover(item: $showing) { category in
                VStack(alignment: .leading, spacing: 12) {
                    Text(category == .overdue ? "逾期任务" : category == .upcoming ? "近期截止" : "未完成任务").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tasks) { task in
                                Button { showing = nil; open(task) } label: {
                                    HStack(alignment: .top) {
                                        Text(task.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        if let due = task.dueAt { Text(shortDate(due)).foregroundStyle(CalendarLogic.deadlinePassed(task, now: now) ? Color.orange : Color.secondary) }
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }.padding(.vertical, 9).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("打开任务：" + task.title)
                                Divider()
                            }
                        }
                    }.frame(maxHeight: 280)
                }.padding(16).frame(width: 360)
            }
    }
    private func countButton(_ title: String, type: SummaryTasks, warning: Bool) -> some View {
        Button(title) { let matches = tasks(for: type); if matches.count == 1, let task = matches.first { open(task) } else { showing = type } }.buttonStyle(.plain).fontWeight(warning ? .semibold : .regular)
            .foregroundStyle(warning ? Color.orange : Color.secondary).help("查看对应任务")
            .accessibilityLabel(store.routeTitle(routeID) + "：" + title)
    }
    private func open(_ task: WorkRecord) {
        store.browse { store.showingAgenda = false; store.search = ""; store.selection = .record(task.id); store.moveTo(task.dueAt ?? task.startAt) }
    }
}
