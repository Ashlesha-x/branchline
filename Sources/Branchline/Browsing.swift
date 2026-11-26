import SwiftUI
import ProgressCore

struct BrowseOffset: Equatable { var x: CGFloat = 0; var y: CGFloat = 0 }
struct BrowseLocation: Equatable {
    var selection: Selection?
    var occurrence: Date?
    var project: UUID?
    var mode: ViewMode
    var page: MainPage
    var category: AgendaScope
    var kind: String
    var search: String
    var searchFilter: SearchEntity?
    var recordFilter: RecordFilter
    var searchPanelVisible: Bool
    var date: Date
    var dayWidth: Double
    var expandedTasks: Set<UUID>
    var expandedFutureTasks: Set<UUID>
    var expanded: Set<String>
    var offsets: [String: BrowseOffset]
    var revision: Int
    var windowSize: CGSize
    var collapsed: [CollapseScope: Set<UUID>]
    var routeDetails: [CollapseScope: [String: Bool]]
    var revealedRoute: UUID?
    var statusGroups: [CollapseScope: [String: Bool]]
}

extension AppStore {
    var browseLocation: BrowseLocation {
        BrowseLocation(selection: selection, occurrence: selectedOccurrence, project: projectFilter, mode: mode, page: mainPage, category: agendaScope, kind: listKind, search: search, searchFilter: searchEntityFilter, recordFilter: recordFilter, searchPanelVisible: searchPanelVisible, date: focusDate, dayWidth: dayWidth, expandedTasks: expandedTaskSeries, expandedFutureTasks: expandedFutureTaskSeries, expanded: expandedGraphRows, offsets: viewportOffsets, revision: workspaceRevision, windowSize: browseWindowSize, collapsed: collapsedByScope, routeDetails: routeDetailChoices, revealedRoute: temporarilyExpandedRoute, statusGroups: routeStatusChoices)
    }
    func browse(_ action: () -> Void) {
        let previous = browseLocation
        restoreOffsets = [:]; revealBrowseSelection = false
        action()
        if previous.selection != selection || previous.project != projectFilter { temporarilyExpandedRoute = selectedRouteID; revealRouteStatus() }
        if previous != browseLocation { browsingHistory.depart(from: previous) }
    }
    func openTrash() {
        editor = nil
        guard editor == nil else { return }
        browse { mainPage = .trash; projectFilter = nil; selection = nil; search = "" }
    }
    /// Shows Settings in the main window, optionally on a given section.
    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
        editor = nil
        guard editor == nil else { return }
        browse { mainPage = .settings; projectFilter = nil; selection = nil; search = "" }
    }
    func canRestore(_ location: BrowseLocation) -> Bool {
        if let project = location.project, workspace.project(project) == nil { return false }
        switch location.selection {
        case .project(let id): return workspace.project(id) != nil
        case .branch(let id): return workspace.branch(id) != nil
        case .merge(let id): return workspace.merges.contains { $0.id == id }
        case .record(let id):
            guard let record = workspace.record(id) else { return false }
            if let occurrence = location.occurrence, record.repeatRule != .none {
                return workspace.reminderDestination(for: ReminderNotificationTarget(recordID: id, occurrence: occurrence))?.occurrence != nil
            }
            return true
        case nil: return true
        }
    }
    var canBrowseBack: Bool { browsingHistory.back.contains(where: canRestore) }
    var canBrowseForward: Bool { browsingHistory.forward.contains(where: canRestore) }
    func browseBack() {
        if let target = browsingHistory.goBack(from: browseLocation, allowing: canRestore) { restoreBrowse(target) }
    }
    func browseForward() {
        if let target = browsingHistory.goForward(from: browseLocation, allowing: canRestore) { restoreBrowse(target) }
    }
    private func restoreBrowse(_ target: BrowseLocation) {
        revealBrowseSelection = target.revision != workspaceRevision || target.windowSize != browseWindowSize || target.collapsed != collapsedByScope || target.routeDetails != routeDetailChoices || target.revealedRoute != temporarilyExpandedRoute
        projectFilter = target.project; mode = target.mode; mainPage = target.page
        agendaScope = target.category; listKind = target.kind; search = target.search; searchEntityFilter = target.searchFilter; recordFilter = target.recordFilter; searchPanelVisible = target.searchPanelVisible
        focusDate = target.date; dayWidth = target.dayWidth; expandedGraphRows = target.expanded; expandedTaskSeries = target.expandedTasks; expandedFutureTaskSeries = target.expandedFutureTasks
        selection = target.selection; selectedOccurrence = target.occurrence
        routeStatusChoices = target.statusGroups
        temporarilyExpandedRoute = target.revealedRoute ?? (revealBrowseSelection ? selectedRouteID : nil)
        if revealBrowseSelection, let id = selectedEntityID {
            revealRouteStatus()
            let record = workspace.record(id)
            let merge = workspace.merges.first { $0.id == id }
            let branchID = record?.branchID ?? merge?.targetBranchID ?? id
            let projects = record.map { workspace.projects(for: $0) }
                ?? merge.map { value in value.targetBranchID.flatMap { workspace.branch($0)?.projectIDs } ?? value.projectID.map { [$0] } ?? [] }
                ?? workspace.branch(branchID)?.projectIDs
                ?? (workspace.project(id) == nil ? [] : [id])
            for project in projects where projectFilter == nil || projectFilter == project {
                let scope: CollapseScope = mode == .graph ? .graph : mode == .list ? .list : .timeline
                if isCollapsed(project, in: scope) { toggleCollapsed(project, in: scope) }
            }
        }
        viewportOffsets = target.offsets; restoreOffsets = target.offsets
        browseRestoreToken = UUID()
    }
    func resetBrowsing() {
        recordFilter = RecordFilter(); searchPanelVisible = false; expandedTaskSeries = []; expandedFutureTaskSeries = []
        searchEntityFilter = nil
        browsingHistory.reset(); viewportOffsets = [:]; restoreOffsets = [:]; browseSpaceToken = UUID()
        temporarilyExpandedRoute = nil
        revealBrowseSelection = false; expandedGraphRows = []; agendaScope = .today; listKind = "all"
        browseRestoreToken = UUID()
    }
    var selectedEntityID: UUID? {
        switch selection { case .project(let id), .branch(let id), .record(let id), .merge(let id): id; case nil: nil }
    }
    func browseAnchor(_ surface: String) -> String? {
        guard let id = selectedEntityID else { return nil }
        if surface == "list", let record = workspace.record(id), let series = workspace.taskFamilyID(for: record), !expandedTaskSeries.contains(series) { return series.uuidString }
        if surface == "agenda" {
            return workspace.agenda(agendaScope, now: Date()).first { $0.record.id == id && (selectedOccurrence == nil || $0.date == selectedOccurrence) }.map { $0.id }
        }
        return id.uuidString
    }
    func trackViewport(_ surface: String, x: CGFloat? = nil, y: CGFloat? = nil) {
        if showingReview { return }
        // Departing SwiftUI views can emit one last, clamped geometry update.
        // It must not replace the position captured before the view switch.
        if showingUtilityPage && surface != (showingTrash ? "trash" : "settings") { return }
        if surface == "trash" && !showingTrash { return }
        if surface == "settings" && !showingSettings { return }
        let agendaVisible = showingAgenda && !isSearching
        if surface == "timeline", mode != .timeline || agendaVisible { return }
        if surface == "graph", mode != .graph || agendaVisible { return }
        if surface == "agenda", !agendaVisible { return }
        if surface == "list", mode != .list || agendaVisible || isSearching { return }
        if surface == "search", !isSearching { return }
        if surface == "inspector", selection == nil { return }
        var value = viewportOffsets[surface] ?? BrowseOffset()
        if let x { value.x = x }; if let y { value.y = y }
        viewportOffsets[surface] = value
    }
    func viewportToRestore(_ surface: String) -> BrowseOffset? { restoreOffsets[surface] ?? viewportOffsets[surface] }
    func changeAgendaScope(_ value: AgendaScope) {
        browse { agendaScope = value; viewportOffsets["agenda"] = BrowseOffset(); browseRestoreToken = UUID() }
    }
    func clearTaskUndo() { taskUndoTimer?.cancel(); taskUndo = nil }
    func completeAgendaTask(_ id: UUID) {
        guard let before = workspace.record(id), before.kind == .task, before.status != .completed else { return }
        do {
            var value = before; value.status = .completed; value.completedAt = Date()
            try saveRecord(value, selectSaved: false)
            guard let completed = workspace.record(id) else { return }
            clearTaskUndo(); taskUndo = TaskCompletionUndo(before: before, completed: completed)
            taskUndoTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled else { return }; self?.taskUndo = nil
            }
            notice = "已完成「\(value.title)」。"
        } catch { self.error = error.localizedDescription }
    }
    func undoAgendaCompletion() {
        guard let action = taskUndo else { return }
        do {
            try commit { try $0.undoTaskCompletion(action) }
            clearTaskUndo(); notice = "已撤销「\(action.before.title)」的完成操作。"
        } catch { clearTaskUndo(); self.error = error.localizedDescription }
    }
    @discardableResult func changeDeadline(_ id: UUID, to day: Date) -> Bool {
        guard let record = workspace.record(id) else { error = "这项任务已不存在。"; return false }
        do { try saveRecord(record.withDeadline(on: day), selectSaved: false); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

private struct BrowseScrollMemory: ViewModifier {
    var store: AppStore
    var surface: String
    @LocalState private var position = ScrollPosition(idType: String.self, y: 0)
    @LocalState private var ready = false
    func body(content: Content) -> some View {
        content.scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y) } action: { _, value in if ready { store.trackViewport(surface, y: value) } }
            .task(id: store.browseRestoreToken) {
                let offset = store.viewportToRestore(surface) ?? BrowseOffset()
                await Task.yield(); guard !Task.isCancelled else { return }
                if store.revealBrowseSelection, surface == "inspector" { position.scrollTo(y: 0) }
                else if store.revealBrowseSelection, let anchor = store.browseAnchor(surface) { position.scrollTo(id: anchor, anchor: .center) }
                else { position.scrollTo(y: offset.y) }
                ready = true
            }
            .onChange(of: store.selection) { _, _ in
                if surface == "inspector", store.restoreOffsets.isEmpty { position.scrollTo(y: 0) }
            }
    }
}
extension View {
    func rememberingBrowsePosition(_ store: AppStore, surface: String) -> some View { modifier(BrowseScrollMemory(store: store, surface: surface)) }
}
