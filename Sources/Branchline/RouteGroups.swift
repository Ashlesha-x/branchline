import SwiftUI
import ProgressCore

extension AppStore {
    private var routePreferenceKey: String { "routePresentation.\(isDemo ? "demo" : workspaceDirectory.path)" }
    func restoreRoutePresentationPreferences() {
        routeRootOrder = (UserDefaults.standard.stringArray(forKey: routePreferenceKey + ".roots") ?? []).compactMap(UUID.init(uuidString:))
        routeStatusChoices = Dictionary(uniqueKeysWithValues: CollapseScope.allCases.map { scope in
            (scope, UserDefaults.standard.dictionary(forKey: routePreferenceKey + ".status." + scope.rawValue) as? [String: Bool] ?? [:])
        })
    }
    func persistRootRouteOrder() { UserDefaults.standard.set(routeRootOrder.map(\.uuidString), forKey: routePreferenceKey + ".roots") }
    func expandedRouteStatuses(in scope: CollapseScope) -> Set<WorkStatus> {
        if isSearching && scope != .sidebar { return Set(RouteGroups.statuses) }
        return Set(RouteGroups.statuses.filter { routeStatusChoices[scope]?[$0.rawValue] == true })
    }
    func toggleRouteStatus(_ status: WorkStatus, in scope: CollapseScope) {
        guard !isSearching else { notice = "搜索时临时展开分组；清空搜索后可调整折叠。"; return }
        routeStatusChoices[scope, default: [:]][status.rawValue] = !expandedRouteStatuses(in: scope).contains(status)
        UserDefaults.standard.set(routeStatusChoices[scope], forKey: routePreferenceKey + ".status." + scope.rawValue)
    }
    func revealRouteStatus() {
        let id = selectedRouteID
        let branch = workspace.branch(id)
        let owner = projectFilter ?? workspace.project(id)?.id ?? (branch.map { workspace.branchIsIndependent($0.id) ? nil : $0.projectIDs.first } ?? nil)
        guard let status = workspace.project(owner)?.status, status != .active else { return }
        for scope in CollapseScope.allCases { routeStatusChoices[scope, default: [:]][status.rawValue] = true }
    }
    var rootRouteIDs: [UUID] {
        workspace.presentedRoutes(projectIDs: workspace.projects.map(\.id), rootOrder: routeRootOrder, expandedStatuses: Set(RouteGroups.statuses))
            .filter { $0.groupStatus == nil && (workspace.project($0.id) != nil || ($0.ownerProjectID == nil && $0.depth == 0)) }.map(\.id)
    }
    func canReorderRoute(_ source: UUID, relativeTo target: UUID) -> Bool {
        guard source != target else { return false }
        let roots = rootRouteIDs
        if roots.contains(source), roots.contains(target) { return (workspace.project(source)?.status ?? .active) == (workspace.project(target)?.status ?? .active) }
        guard !roots.contains(source), !roots.contains(target), workspace.canReorder(source, relativeTo: target), workspace.branch(source)?.originBranchID == workspace.branch(target)?.originBranchID else { return false }
        let all = workspace.routePlacements(projectIDs: workspace.projects.map(\.id), includeAllIndependent: true)
        return all.first { $0.id == source }?.ownerProjectID == all.first { $0.id == target }?.ownerProjectID
    }
    func routeGroupProjects(_ status: WorkStatus, in scope: CollapseScope) -> [Project] {
        let projects = scope == .sidebar ? workspace.projects : visibleProjects
        return projects.filter { $0.status == status }
    }
    func routeStatus(of record: WorkRecord) -> WorkStatus? {
        if let branch = record.branchID, workspace.branchIsIndependent(branch), projectFilter == nil { return nil }
        let ids = workspace.projects(for: record)
        let projects = visibleProjects.filter { ids.contains($0.id) }
        if projects.contains(where: { $0.status == .active }) { return nil }
        return RouteGroups.statuses.first { status in projects.contains { $0.status == status } }
    }
}

struct RouteStatusButton: View {
    @Bindable var store: AppStore
    var status: WorkStatus
    var scope: CollapseScope
    var compact = false
    var showTitle = true
    var body: some View {
        let projects = store.routeGroupProjects(status, in: scope)
        let ids = Set(projects.map(\.id))
        let pending = store.workspace.records.filter { $0.kind == .task && $0.status == .active && !ids.isDisjoint(with: store.workspace.projects(for: $0)) }
        let overdue = pending.filter { CalendarLogic.deadlinePassed($0, now: Date()) }.count
        Button { store.toggleRouteStatus(status, in: scope) } label: {
            HStack(spacing: 7) {
                if showTitle {
                    Image(systemName: store.expandedRouteStatuses(in: scope).contains(status) ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                    Text(status.title).fontWeight(.medium)
                    Text("\(projects.count)").foregroundStyle(.secondary)
                } else { Text("\(projects.count) 个项目").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if !compact, !pending.isEmpty { Text("未完成 \(pending.count)").foregroundStyle(.secondary) }
                if overdue > 0 { Text("\(overdue) 逾期").foregroundStyle(.orange).font(.caption2) }
            }.font(.caption).padding(.horizontal, compact ? 7 : 12).frame(maxWidth: .infinity, minHeight: 34).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(status.title) · \(projects.count) 个项目 · 未完成 \(pending.count) · 逾期 \(overdue)")
            .accessibilityLabel("\(scope == .sidebar ? "侧栏" : scope == .graph ? "脉络图" : scope == .list ? "列表" : showTitle ? "时间轴" : "时间轴概况")：\(store.expandedRouteStatuses(in: scope).contains(status) ? "收起" : "展开")\(status.title)项目，\(projects.count) 个")
    }
}
