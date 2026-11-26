import SwiftUI
import Observation
import UniformTypeIdentifiers
import ProgressCore

enum Selection: Hashable { case project(UUID), branch(UUID), record(UUID), merge(UUID) }
struct RecurringEdit { let seriesID: UUID; let occurrence: Date; let scope: RecurrenceScope }
enum EditorRoute: Identifiable {
    case project(Project), branch(Branch), record(WorkRecord), progressDraft(WorkRecord, Bool), recurring(WorkRecord, RecurringEdit), merge(UUID), restoredDraft(RecordDraft)
    var id: String {
        switch self { case .project(let p): "project-\(p.id)"; case .branch(let b): "branch-\(b.id)"; case .record(let r): "record-\(r.id)"; case .progressDraft(let r, _): "draft-\(r.id)"; case .recurring(let r, let edit): "recurring-\(r.id)-\(edit.scope.rawValue)"; case .merge(let id): "merge-\(id)"; case .restoredDraft(let d): "restored-\(d.id)" }
    }
}
enum CollapseScope: String, CaseIterable { case sidebar, list, timeline, graph }

enum MainPage { case projects, agenda, trash, settings, review }

enum ViewMode: String, CaseIterable { case timeline = "时间轴", graph = "脉络图", list = "列表" }

@MainActor @Observable final class AppStore {
    var workspace = Workspace() { didSet { cachedSearch = nil; workspaceRevision += 1 } }
    private(set) var workspaceRevision = 0
    @ObservationIgnored private var cachedSearch: (query: String, project: UUID?, filter: RecordFilter, all: Bool, hits: [SearchHit], ids: Set<UUID>)?
    var selection: Selection? { didSet { if selection != oldValue { selectedOccurrence = nil; pinnedRelationID = nil; hoveredRelationID = nil } } }
    var selectedOccurrence: Date?
    var projectFilter: UUID? { didSet { if projectFilter != oldValue { pinnedRelationID = nil; hoveredRelationID = nil } } }
    var mode: ViewMode = .timeline
    private var presentedEditor: EditorRoute?
    var editor: EditorRoute? {
        get { presentedEditor }
        set {
            if newValue != nil && fileDialogPending { return }
            if newValue != nil, presentedEditor == nil, quickRecord != nil {
                guard EditorProtection.shared.resolve() else { return }
                endQuickProgress()
            }
            if presentedEditor != nil, presentedEditor?.id != newValue?.id, !EditorProtection.shared.resolve() { return }
            if let newValue, let draft = matchingDraft(for: newValue) { presentedEditor = .restoredDraft(draft) }
            else { presentedEditor = newValue }
        }
    }
    var recordDrafts: [RecordDraft] = []
    var draftRecoveryCollapsed = false
    var expandedFutureTaskSeries: Set<UUID> = []
    var draftSavedAt: Date?
    var draftError: String?
    @ObservationIgnored var draftWriteTask: Task<Void, Never>?
    @ObservationIgnored var draftReadFailed = false
    @ObservationIgnored var draftNeedsWrite = false
    var mainPage: MainPage = .projects
    var showingAgenda: Bool {
        get { mainPage == .agenda }
        set { mainPage = newValue ? .agenda : .projects }
    }
    var showingReview: Bool { mainPage == .review }
    var showingTrash: Bool { mainPage == .trash }
    var showingSettings: Bool { mainPage == .settings }
    var showingUtilityPage: Bool { showingTrash || showingSettings }
    var agendaScope: AgendaScope = .today
    var listKind = "all"
    var expandedGraphRows: Set<String> = []
    var browsingHistory = BrowsingHistory<BrowseLocation>()
    @ObservationIgnored var viewportOffsets: [String: BrowseOffset] = [:]
    @ObservationIgnored var restoreOffsets: [String: BrowseOffset] = [:]
    var browseRestoreToken = UUID()
    var browseSpaceToken = UUID()
    @ObservationIgnored var browseWindowSize: CGSize = .zero
    var revealBrowseSelection = false
    var taskUndo: TaskCompletionUndo?
    @ObservationIgnored var taskUndoTimer: Task<Void, Never>?
    var deadlineEditorID: UUID?
    var quickRecord: WorkRecord? { didSet { registerQuickProtection() } }
    var quickVisible = false
    var quickLocationAttempted = false
    var quickLocationFocusRequest = 0
    var quickError: String?
    var quickNotice = ""
    @ObservationIgnored var quickBaseline: WorkRecord?
    @ObservationIgnored let quickOwner = UUID()
    @ObservationIgnored var quickSurface: QuickSurface = .main
    var error: String?
    var startupError: String?
    var notice = "" {
        didSet {
            if !oldValue.isEmpty && quickNotice == oldValue { quickNotice = "" }
            scheduleNoticeExpiry()
        }
    }
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    var iCloudBackupMessage = ""
    private(set) var fileDialogPending = false
    var iCloudBackupFailed = false
    var lastICloudBackupURL: URL?
    var lastICloudBackupAt: Date?
    var lastICloudBackupSpace = ""
    var iCloudAutoEnabled = false
    var iCloudBackupMinutes = 20 * 60
    var iCloudAutoEnabledSince: Date?
    var lastPersonalICloudBackupAt: Date?
    var lastPersonalICloudFingerprint: String?
    var iCloudHasChanges = true
    var iCloudBackups: [ICloudBackupEntry] = []
    @ObservationIgnored var iCloudBackupMonitor: Task<Void, Never>?
    @ObservationIgnored var nextICloudBackupAttempt = Date.distantPast
    var isDemo = false
    var routeDetailChoices: [CollapseScope: [String: Bool]] = [:]
    var temporarilyExpandedRoute: UUID?
    var routeRootOrder: [UUID] = [] { didSet { routeLayoutCache.removeAll() } }
    var routeStatusChoices: [CollapseScope: [String: Bool]] = [:] { didSet { routeLayoutCache.removeAll() } }
    @ObservationIgnored var routeLayoutCache: [CollapseScope: (Int, UUID?, Set<UUID>, Set<WorkStatus>, [RoutePlacement])] = [:]
    var pinnedRelationID: String?
    var hoveredRelationID: String?
    private(set) var collapsedByScope: [CollapseScope: Set<UUID>] = [:]
    var savedAt: Date?
    var search = "" { didSet { if search != oldValue { searchEntityFilter = nil } } }
    var recordFilter = RecordFilter() { didSet { cachedSearch = nil } }
    var searchPanelVisible = false
    var reviewDraft = ReviewDraft.currentWeek() { didSet { if reviewDraft != oldValue { scheduleReviewSave() } } }
    var reviewPreset: ReviewPreset { get { ReviewPreset(rawValue: reviewDraft.preset) ?? .custom } set { reviewDraft.preset = newValue.rawValue } }
    var reviewFrom: Date { get { reviewDraft.from } set { reviewDraft.from = newValue } }
    var reviewThrough: Date { get { reviewDraft.through } set { reviewDraft.through = newValue } }
    var reviewProjectID: UUID? { get { reviewDraft.projectID } set { reviewDraft.projectID = newValue } }
    var reviewBranchID: UUID? { get { reviewDraft.branchID } set { reviewDraft.branchID = newValue } }
    var reviewReport: WorkReview? { reviewDraft.report }
    var reviewText: String { get { reviewDraft.text } set { reviewDraft.text = newValue } }
    var reviewSaveStatus = ""
    @ObservationIgnored var reviewSaveTask: Task<Void, Never>?
    @ObservationIgnored var reviewLoading = false
    @ObservationIgnored var reviewReadFailed = false
    @ObservationIgnored var reviewNeedsWrite = false
    var expandedTaskSeries: Set<UUID> = []
    let calendarService = AppleCalendarService()
    var searchEntityFilter: SearchEntity?
    var focusDate = Date()
    var dayWidth: Double = 88
    var navigationToken = UUID()
    let notifications = ReminderService()
    let loginItem = LoginItemService()
    let dataDirectory: URL
    private var repository: WorkspaceRepository?
    private var personalRepository: WorkspaceRepository?
    @ObservationIgnored private var processLock: WorkspaceProcessLock?
    @ObservationIgnored private var bridge: LocalBridgeServer?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    /// The latest deletion stays undoable from the status bar for a few seconds only.
    var recentDeletionID: UUID?
    @ObservationIgnored private var recentDeletionTask: Task<Void, Never>?
    var automationMode = "readWrite"
    var automationRunning: Bool { bridge != nil }
    private(set) var automationStartupError: String?

    private func scheduleNoticeExpiry() {
        noticeTask?.cancel()
        guard !notice.isEmpty else { return }
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.notice = ""
        }
    }


    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let directory = Bundle.main.object(forInfoDictionaryKey: "BranchlineDataDirectory") as? String {
            dataDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        } else if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Branchline", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            processLock = try WorkspaceProcessLock(directory: dataDirectory)
            let repo = try WorkspaceRepository(url: dataDirectory.appendingPathComponent("personal.store"))
            try recoverInterruptedMigration(using: repo)
            personalRepository = repo; repository = repo
            var loaded = try repo.load() ?? Workspace()
            if loaded.pruneExpired(now: Date()) { try? repo.save(loaded) }
            workspace = loaded
            pruneBackupFiles()
            loadDrafts()
            refreshRecurringTasks()
            restoreCollapsed(); restoreRouteDetails()
            if arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "BranchlineDemo") as? Bool == true { try switchSpace(demo: true) }
            else { notifications.refresh(workspace: workspace, demo: false) }
            automationMode = initialAutomationMode()
            do {
                bridge = try LocalBridgeServer(directory: dataDirectory) { [weak self] request in
                    guard let self else { return .object(["ok": .bool(false), "error": .string("app_closed")]) }
                    return self.handleAutomation(request)
                }
            } catch { automationStartupError = error.localizedDescription }
        } catch { startupError = "无法打开本地资料库。原文件未被替换。\n\(error.localizedDescription)" }
        startICloudBackupMonitor()
        // The main window's view hierarchy is gone in menu-bar mode, so flush here.
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushDrafts(); self?.flushReviewDraft()
                self?.bridge?.invalidate()
            }
        }
    }
    /// New data directories start with the local API off. A directory that already ran an
    /// earlier version (its endpoint file exists) keeps the previous default of read/write.
    private func initialAutomationMode() -> String {
        let key = "automationMode." + dataDirectory.path
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let earlier = FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("automation-endpoint.json").path)
        let mode = earlier ? "readWrite" : "off"
        UserDefaults.standard.set(mode, forKey: key)
        return mode
    }
    /// Snapshots written before deletions, external writes and restores are kept for the
    /// same retention window as the trash. Format-upgrade snapshots are never removed.
    func pruneBackupFiles(now: Date = Date()) {
        let directory = dataDirectory.appendingPathComponent("Backups", isDirectory: true)
        let cutoff = now.addingTimeInterval(-Double(Workspace.retentionDays) * 86_400)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where ["before-delete-", "before-automation-", "before-restore-"].contains(where: { file.lastPathComponent.hasPrefix($0) }) && file.pathExtension == "json" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    func switchSpace(demo: Bool) throws {
        guard startupError == nil else { throw WorkspaceError("请先解决资料库打开错误。") }
        guard !fileDialogPending else { notice = "请先完成或取消文件选择，再切换空间。"; return }
        guard EditorProtection.shared.resolve() else { return }
        flushDrafts(); flushReviewDraft()
        endQuickProgress()
        let repo: WorkspaceRepository
        let value: Workspace
        if demo {
            repo = try WorkspaceRepository(inMemory: true); value = .demo(); try repo.save(value)
        } else {
            guard let personalRepository else { throw WorkspaceError("个人资料库不可用。") }
            repo = personalRepository; value = try repo.load() ?? Workspace()
        }
        resetBrowsing(); clearTaskUndo(); deadlineEditorID = nil
        repository = repo; workspace = value; isDemo = demo
        loadDrafts()
        selection = nil; projectFilter = nil; search = ""; editor = nil; showingAgenda = false; focusDate = Date(); navigationToken = UUID()
        restoreCollapsed(); restoreRouteDetails(); pinnedRelationID = nil; hoveredRelationID = nil; notice = demo ? "已切换到示例空间。" : "已切换到个人空间。"
        if !demo { notifications.refresh(workspace: value, demo: false) }
    }
    func commit(_ mutate: (inout Workspace) throws -> Void) throws {
        guard startupError == nil, let repository else { throw WorkspaceError("资料库未就绪，未保存任何修改。") }
        var next = workspace; try mutate(&next)
        next.pruneExpired(now: Date())
        // Strict day-order checks only for what this write changed; see Workspace.validate(strictDayOrder:).
        try next.validate(strictDayOrder: next.dayOrderChanges(since: workspace)); try repository.save(next)
        let previous = workspace
        workspace = next; savedAt = Date()
        if !isDemo { scheduleCalendarWriteBack(since: previous) }
        if !isDemo { notifications.refresh(workspace: next, demo: false) }
        if !isDemo { checkAutomaticICloudBackup() }
    }
    func personalWorkspaceSnapshot() throws -> Workspace { try personalRepository?.load() ?? Workspace() }
    func savedPersonalBackupData() throws -> Data? { try migrationSnapshot(personal: true).encoded() }
    func setAutomationMode(_ mode: String) {
        automationMode = mode
        UserDefaults.standard.set(mode, forKey: "automationMode." + dataDirectory.path)
    }
    func handleAutomation(_ request: JSONValue) -> JSONValue {
        do {
            guard startupError == nil else { throw WorkspaceError("workspace_unavailable") }
            guard automationMode != "off" else { throw WorkspaceError("access_disabled: 请在设置中开启本地接口。") }
            guard !isDemo else { throw WorkspaceError("demo_space: 请切回个人空间后调用，防止操作临时示例。") }
            let method = try AutomationAPI.requireString(request, "method")
            let args = request["arguments"]
            let result: JSONValue
            if method == "preview_changes" || method == "apply_changes" {
                if method == "apply_changes" {
                    guard automationMode == "readWrite" else { throw WorkspaceError("read_only") }
                    guard presentedEditor == nil && quickRecord == nil && deadlineEditorID == nil else { throw WorkspaceError("editor_open: 请先保存或关闭编辑器，再执行外部修改。") }
                    guard !fileDialogPending && NSApp.modalWindow == nil else { throw WorkspaceError("dialog_open: 请先完成或关闭当前对话框，再执行外部修改。") }
                }
                let plan = try AutomationAPI.plan(args, in: workspace)
                if method == "apply_changes" && !plan.replay {
                    let backups = dataDirectory.appendingPathComponent("Backups")
                    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                    try workspace.encoded().write(to: backups.appendingPathComponent("before-automation-\(UUID().uuidString).json"), options: .atomic)
                    try commit { $0 = plan.workspace }
                    pruneBackupFiles()
                    if plan.receipt.changes.contains(where: { change in
                        change["entity"].string == "record" && change["id"].string.flatMap(UUID.init(uuidString:)).flatMap { workspace.record($0) }?.hasReminders == true
                    }) { notifications.requestAndRefresh(workspace: workspace) }
                    notice = "AI 客户端已保存 \(plan.receipt.changes.count) 项操作"
                }
                result = .object(["revision": .string(workspace.automationRevision), "applied": .bool(method == "apply_changes"), "replayed": .bool(plan.replay), "receipt": try .from(plan.receipt)])
            } else { result = try AutomationAPI.query(method, arguments: args, workspace: workspace) }
            return .object(["ok": .bool(true), "result": result])
        } catch { return .object(["ok": .bool(false), "error": .string(error.localizedDescription), "revision": .string(workspace.automationRevision)]) }
    }
    func saveProject(_ input: Project) throws {
        var project = input
        if project.status != .archived && workspace.occupiedRouteColors(excluding: project.id).contains(project.color) { project.color = workspace.availableRouteColor(excluding: project.id) }
        let old = workspace.project(project.id)
        try commit { try $0.putProject(project) }
        if (project.status == .completed || project.status == .archived) && old?.status != project.status {
            for scope in CollapseScope.allCases {
                collapsedByScope[scope, default: []].insert(project.id)
                persistCollapsed(in: scope)
            }
        }
        restoreOffsets = [:]; revealBrowseSelection = false
        selection = .project(project.id)
        notice = "已保存项目「\(project.title)」。"
    }
    func saveBranch(_ input: Branch) throws {
        var branch = input
        if branch.status != .archived && workspace.occupiedRouteColors(excluding: branch.id).contains(branch.color) { branch.color = workspace.availableRouteColor(excluding: branch.id) }
        try commit { try $0.putBranch(branch) }
        restoreOffsets = [:]; revealBrowseSelection = false
        selection = .branch(branch.id)
        notice = "已保存分支「\(branch.title)」。"
    }
    func saveRecord(_ input: WorkRecord, recurrence: RecurringEdit? = nil, selectSaved: Bool = true, taskScope: RecurrenceScope = .occurrence) throws {
        var record = input; record.updatedAt = Date()
        if record.status == .completed && record.completedAt == nil { record.completedAt = Date() }
        if record.status != .completed { record.completedAt = nil }
        let stored = workspace.record(record.id)
        let old = recurrence.map { $0.scope == .series ? stored : stored?.occurrenceDraft(at: $0.occurrence) } ?? stored
        if let old, old.reminderDates == record.reminderDates, !record.reminderDates.isEmpty,
           old.startAt != record.startAt || old.dueAt != record.dueAt || old.dateOnly != record.dateOnly || old.dueDateOnly != record.dueDateOnly {
            let delta = record.rescheduleDelta(from: old)
            let alert = NSAlert(); alert.messageText = "如何处理原有固定提醒？"
            alert.informativeText = "相对提醒会自动跟随日期。原有固定提醒需要你确认。" + (delta == nil ? "本次改动无法确定移动幅度，可保持原时间或返回编辑。" : "选择随改期移动时，优先按截止日期变化量移动；否则按开始时间变化量移动。")
            alert.addButton(withTitle: "继续编辑")
            alert.addButton(withTitle: "保持原时间")
            if delta != nil { alert.addButton(withTitle: "随改期移动") }
            let response = DialogPresentation.confirm(alert)
            if response == .alertThirdButtonReturn, let delta { record.reminderDates = record.reminderDates.map { $0.addingTimeInterval(delta) } }
            else if response != .alertSecondButtonReturn { throw WorkspaceError("尚未保存，请核对固定提醒时间后再保存。") }
        }
        if record.status == .completed && old?.status != .completed && !workspace.blockedBy(record).isEmpty {
            throw WorkspaceError("这项任务还有未完成的依赖。请先完成依赖，或编辑任务调整依赖关系。")
        }
        var selectedID = record.id
        try commit { db in
            if let recurrence {
                let previousIDs = Set(db.records.map(\.id))
                db = try db.editingRecurring(recurrence.seriesID, occurrence: recurrence.occurrence, input: record, scope: recurrence.scope)
                selectedID = db.records.first { !previousIDs.contains($0.id) }?.id ?? record.id
                return
            }
            if record.taskSeriesID != nil {
                let previousPlans = Set((db.taskPlans ?? []).map(\.id))
                db = try db.editingTaskPlan(record, scope: taskScope)
                if taskScope == .following, stored?.status == .completed || stored?.status == .archived,
                   let plan = db.taskPlans?.first(where: { !previousPlans.contains($0.id) }),
                   let pending = db.records.filter({ $0.taskSeriesID == plan.id && ($0.status == .active || $0.status == .paused) }).min(by: { ($0.taskOccurrence ?? .distantFuture) < ($1.taskOccurrence ?? .distantFuture) }) { selectedID = pending.id }
                return
            }
            if record.kind == .task && record.taskSeriesID == nil && record.taskRepeatRule.map({ $0 != .none }) == true { try db.createTaskPlan(from: record) }
            else { try db.putRecord(record) }
        }
        if selectSaved { restoreOffsets = [:]; revealBrowseSelection = false; selection = .record(selectedID); selectedOccurrence = nil }
        if record.kind == .progress || stored == nil { rememberRecordingLocation(record.recordingLocation) }
        let saved = workspace.record(selectedID) ?? record
        let location = saved.recordingLocation?.title(in: workspace) ?? "当前工作区"
        notice = "已保存\(saved.kind.title)到「\(location)」。"
        if !isDemo && record.hasReminders { notifications.requestAndRefresh(workspace: workspace) }
    }
    func saveMerge(_ merge: MergeRecord) throws {
        try commit { try $0.addMerge(merge) }
        restoreOffsets = [:]; revealBrowseSelection = false
        selection = .merge(merge.id)
        notice = "已合并成果到「\(workspace.mergeTargetTitle(merge))」。"
    }
    func collapsedIDs(in scope: CollapseScope) -> Set<UUID> {
        isSearching && scope != .sidebar ? [] : (collapsedByScope[scope] ?? [])
    }
    func isCollapsed(_ id: UUID, in scope: CollapseScope) -> Bool { collapsedIDs(in: scope).contains(id) }
    func toggleCollapsed(_ id: UUID, in scope: CollapseScope) {
        guard !isSearching || scope == .sidebar else { notice = "搜索时临时展开路线；清空搜索后可调整折叠。"; return }
        if isCollapsed(id, in: scope) { collapsedByScope[scope, default: []].remove(id) }
        else { collapsedByScope[scope, default: []].insert(id) }
        persistCollapsed(in: scope)
    }
    private var collapseKey: String { "collapsed.\(isDemo ? "demo" : dataDirectory.path)" }
    private func restoreCollapsed() {
        let defaults = Set(workspace.projects.filter { $0.status == .completed || $0.status == .archived }.map(\.id))
        let validIDs = Set(workspace.projects.map(\.id))
        for scope in CollapseScope.allCases {
            if isDemo { collapsedByScope[scope] = defaults; continue }
            // Seed each independent value from the old shared preference on first upgrade.
            let values = UserDefaults.standard.stringArray(forKey: "\(collapseKey).\(scope.rawValue)") ?? UserDefaults.standard.stringArray(forKey: collapseKey)
            collapsedByScope[scope] = values.map { Set($0.compactMap(UUID.init(uuidString:))).intersection(validIDs) } ?? defaults
        }
    }
    private func persistCollapsed(in scope: CollapseScope) {
        UserDefaults.standard.set((collapsedByScope[scope] ?? []).map(\.uuidString), forKey: "\(collapseKey).\(scope.rawValue)")
    }
    func newRecord(_ kind: RecordKind = .progress, branchID: UUID? = nil, projectID: UUID? = nil) {
        var item = WorkRecord(kind: kind, title: "")
        let explicit = branchID.map { RecordingLocation(branchID: $0) } ?? projectID.map { RecordingLocation(projectIDs: [$0]) }
        if let location = workspace.recordingLocation(explicit: explicit, context: recordingContext, projectFilter: projectFilter) { item = location.applying(to: item) }
        if kind == .meeting { item.endAt = Date().addingTimeInterval(3600) }
        editor = .record(item)
    }
    func newBranch(projectID: UUID) {
        var branch = Branch(projectIDs: [projectID])
        branch.originProjectID = projectID
        editor = .branch(branch)
    }
    func newChildBranch(parentID: UUID) {
        guard let parent = workspace.branch(parentID) else { return }
        var branch = Branch(projectIDs: parent.projectIDs)
        branch.originBranchID = parent.id
        branch.startAt = max(Date(), parent.startAt)
        editor = .branch(branch)
    }
    func reorderRoute(_ source: UUID, relativeTo target: UUID, after: Bool) {
        guard canReorderRoute(source, relativeTo: target) else { return }
        if rootRouteIDs.contains(source), rootRouteIDs.contains(target) {
            routeRootOrder = RouteGroups.reordered(rootRouteIDs, moving: source, to: target, after: after)
            persistRootRouteOrder()
            return
        }
        do { try commit { $0 = try $0.reordering(source, relativeTo: target, after: after) } }
        catch { self.error = error.localizedDescription }
    }
    func moveTo(_ date: Date) { restoreOffsets = [:]; focusDate = date; navigationToken = UUID() }
    @discardableResult func openReminder(_ target: ReminderNotificationTarget) -> Bool {
        guard !fileDialogPending else { notice = "请先完成文件选择，再打开这条通知。"; return false }
        guard let destination = workspace.reminderDestination(for: target) else {
            notice = "通知对应的记录已删除或不可用。"
            return true
        }
        guard EditorProtection.shared.resolve() else { return false }
        browse {
            endQuickProgress(); editor = nil
            search = ""; searchPanelVisible = false; projectFilter = nil; showingAgenda = false
            selection = .record(destination.recordID)
            // Always replace this value, including when the same series is already selected.
            selectedOccurrence = destination.occurrence
            if workspace.record(destination.recordID)?.kind == .meeting { mode = .timeline }
            moveTo(destination.focusDate)
        }
        notice = destination.message ?? ""
        return true
    }
    func editRecurring(_ record: WorkRecord, scope: RecurrenceScope) {
        let date = selectedOccurrence ?? record.startAt
        editor = .recurring(scope == .series ? record : record.occurrenceDraft(at: date), RecurringEdit(seriesID: record.id, occurrence: date, scope: scope))
    }
    func requestRecurringDeletion(_ record: WorkRecord, scope: RecurrenceScope) {
        do {
            let date = selectedOccurrence ?? record.startAt
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "删除会议：\(scope.rawValue)？"
            let detail: String
            switch scope {
            case .occurrence: detail = "只取消所选日期，其他次会议保留。本次删除可从回收站恢复。"
            case .following: detail = "取消所选日期及此后的会议，包括此后已单独修改的例外；过去部分保留。本次删除可从回收站恢复。"
            case .series: detail = try workspace.deletionPreview(.record(record.id)).detail
            }
            alert.informativeText = "「\(record.title)」\n\(WorkDateText.meeting(record, occurrence: date))\n\n\(detail)\n\n拆分后的其他系列独立管理。"
            alert.addButton(withTitle: "取消").keyEquivalent = "\r"
            alert.addButton(withTitle: "确认删除").hasDestructiveAction = true
            guard DialogPresentation.confirm(alert) == .alertSecondButtonReturn else { return }
            let next = try workspace.deletingRecurring(record.id, occurrence: date, scope: scope).retainingDeletion(from: workspace, title: "\(record.title) · \(scope.rawValue)")
            try commitDeletion(next)
        } catch { self.error = error.localizedDescription }
    }
    func restoreDeletion(_ id: UUID) {
        do {
            try commit { $0 = try $0.restoringTrash(id) }
            if recentDeletionID == id { recentDeletionID = nil }
            notice = "已恢复本次删除；之后的其他内容保留。"
        } catch { self.error = error.localizedDescription }
    }
    func requestDeletion(_ target: DeletionTarget) {
        do {
            let preview = try workspace.deletionPreview(target)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "删除「\(preview.title)」？"
            alert.informativeText = preview.detail
            alert.addButton(withTitle: "取消")
            let deleteButton = alert.addButton(withTitle: "确认删除")
            deleteButton.hasDestructiveAction = true
            let next = try workspace.movingToTrash(target)
            let linked = isDemo || !calendarService.connected ? [] : next.removedCalendarLinks(since: workspace)
            if !linked.isEmpty {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = linked.count == 1 ? "同时删除 Apple 日历中的这个事件" : "同时删除 Apple 日历中的 \(linked.count) 个事件"
                alert.suppressionButton?.state = .off
            }
            guard DialogPresentation.confirm(alert) == .alertSecondButtonReturn else { return }
            let removeEvents = alert.suppressionButton?.state == .on
            try commitDeletion(next)
            if removeEvents {
                do { let count = try calendarService.deleteEvents(for: linked); notice = "已移入回收站，并删除 \(count) 个日历事件。" }
                catch { self.error = "已移入回收站，但日历事件未删除：" + error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func commitDeletion(_ next: Workspace) throws {
            let directory = dataDirectory.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let backup = directory.appendingPathComponent("before-delete-\(fileDate(Date()))-\(UUID().uuidString).json")
            try workspace.encoded().write(to: backup, options: .atomic)
            try commit { $0 = next }
            pruneBackupFiles()
            if let projectFilter, next.project(projectFilter) == nil { self.projectFilter = nil }
            switch selection {
            case .project(let id): if next.project(id) == nil { selection = nil }
            case .branch(let id): if next.branch(id) == nil { selection = nil }
            case .record(let id): if next.record(id) == nil { selection = nil }
            case .merge(let id): if !next.merges.contains(where: { $0.id == id }) { selection = nil }
            case nil: break
            }
            for scope in CollapseScope.allCases {
                collapsedByScope[scope] = collapsedIDs(in: scope).intersection(next.projects.map(\.id))
                persistCollapsed(in: scope)
            }
            selectedOccurrence = nil
            notice = "已移入回收站，可撤销本次删除。回收站内容保留 \(Workspace.retentionDays) 天。"
            recentDeletionID = next.trash.last?.id
            recentDeletionTask?.cancel()
            recentDeletionTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.recentDeletionID = nil
            }
    }
    func openBackupFolder() {
        do {
            let directory = dataDirectory.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { self.error = error.localizedDescription }
    }
    var visibleProjects: [Project] { workspace.projects.filter { projectFilter == nil || $0.id == projectFilter } }
    var isSearching: Bool { searchPanelVisible || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var searchHits: [SearchHit] {
        _ = workspaceRevision
        if let cachedSearch, cachedSearch.query == search, cachedSearch.project == projectFilter, cachedSearch.filter == recordFilter, cachedSearch.all == searchPanelVisible { return cachedSearch.hits }
        var filter = recordFilter; filter.projectID = projectFilter
        let base: [SearchHit] = workspace.search(search, projectID: projectFilter, includeAll: searchPanelVisible)
        var hits: [SearchHit] = []
        for hit in base where filter.matches(hit, in: workspace) {
            var result: SearchHit = hit
            if hit.kind == .record, let record = workspace.record(hit.id), let date = filter.dateField.date(of: record) { result.date = date }
            hits.append(result)
        }
        hits.sort { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }

        cachedSearch = (search, projectFilter, recordFilter, searchPanelVisible, hits, Set(hits.map(\.id)))
        return hits
    }
    var matchingIDs: Set<UUID> { _ = searchHits; return cachedSearch?.ids ?? [] }
    func searchOpacity(_ id: UUID) -> Double { !isSearching || matchingIDs.contains(id) ? 1 : 0.3 }
    var filteredRecords: [WorkRecord] {
        workspace.records.filter { projectFilter == nil || workspace.projects(for: $0).contains(projectFilter!) }
    }
    func showSearchHit(_ hit: SearchHit, inContext: Bool = false) {
        browse {
            if inContext { search = ""; searchPanelVisible = false; showingAgenda = false; if mode == .list { mode = .timeline } }
            switch hit.kind {
            case .project: selection = .project(hit.id)
            case .branch: selection = .branch(hit.id)
            case .record: selection = .record(hit.id)
            case .merge: selection = .merge(hit.id)
            }
            moveTo(hit.date)
        }
    }

    func exportBackup() {
        guard !fileDialogPending else { return }
        do {
            let snapshot = try migrationSnapshot().encoded()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "脉络迁移备份-\(fileDate(Date())).json"
            fileDialogPending = true
            if !DialogPresentation.chooseFile(panel, completion: { [weak self] response in
                guard let self else { return }
                defer { self.fileDialogPending = false }
                guard response == .OK, let url = panel.url else { return }
                do { try snapshot.write(to: url, options: .atomic); self.notice = "迁移备份已导出，包含正式内容与草稿。" }
                catch { self.error = error.localizedDescription }
            }) { fileDialogPending = false; notice = "请先关闭当前编辑窗口，再导出备份。" }
        } catch { self.error = error.localizedDescription }
    }
    func exportICloudBackup() {
        guard startupError == nil else {
            iCloudBackupFailed = true
            iCloudBackupMessage = "资料库未就绪，未创建备份。"
            return
        }
        do {
            guard !isDemo else { return }
            try writeICloudBackup(migrationSnapshot().encoded(), demo: false)
            notice = "已备份到 iCloud 云盘。"
        } catch {
            iCloudBackupFailed = true
            iCloudBackupMessage = "备份未完成：\(error.localizedDescription)"
        }
    }
    func importBackup() {
        guard !fileDialogPending else { return }
        guard presentedEditor == nil else { notice = "请先保存或关闭编辑窗口，再恢复备份。"; return }
        guard EditorProtection.shared.resolve() else { return }
        endQuickProgress()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        let revision = workspaceRevision
        fileDialogPending = true
        if !DialogPresentation.chooseFile(panel, completion: { [weak self] response in
            guard let self else { return }
            defer { self.fileDialogPending = false }
            guard response == .OK, let url = panel.url else { return }
            do {
                guard self.workspaceRevision == revision else { throw WorkspaceError("当前空间内容已变化，请重新选择备份。") }
                try self.restoreBackup(from: url, revision: revision)
            } catch { self.error = error.localizedDescription }
        }) { fileDialogPending = false; notice = "请先关闭当前编辑窗口，再选择恢复备份。" }
    }
    /// Restores a backup file chosen from a list (for example the iCloud backups in Settings).
    func restoreBackup(at url: URL) {
        guard !fileDialogPending else { return }
        guard presentedEditor == nil else { notice = "请先保存或关闭编辑窗口，再恢复备份。"; return }
        guard EditorProtection.shared.resolve() else { return }
        endQuickProgress()
        do { try restoreBackup(from: url, revision: workspaceRevision) } catch { self.error = error.localizedDescription }
    }
    func restoreBackup(from url: URL, revision: Int) throws {
        let bytes = try Data(contentsOf: url)
        guard bytes.count < 100_000_000 else { throw WorkspaceError("备份超过 100 MB，请先检查文件。") }
        let decoded = try MigrationBackup.decoded(bytes)
        let previous = try migrationSnapshot()
        let next = MigrationBackup(workspace: decoded.workspace, drafts: decoded.includesDrafts ? decoded.drafts : previous.drafts, review: decoded.includesReview ? decoded.review : previous.review)
        let alert = NSAlert(); alert.messageText = "恢复这份备份？"
        alert.informativeText = "将恢复 \(next.workspace.projects.count) 个项目、\(next.workspace.branches.count) 条分支、\(next.workspace.records.count) 条记录和 \(next.drafts.count) 份草稿。" + (decoded.includesDrafts ? "草稿仍保留为草稿。" : "这是旧版备份，当前草稿会保留。") + "当前正式内容与草稿会先保存为独立迁移备份。"
        alert.addButton(withTitle: "备份当前内容并恢复"); alert.addButton(withTitle: "取消")
        guard DialogPresentation.confirm(alert) == .alertFirstButtonReturn else { return }
        guard workspaceRevision == revision else { throw WorkspaceError("当前空间内容已变化，请重新选择备份。") }
        let directory = dataDirectory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try previous.encoded().write(to: directory.appendingPathComponent("before-restore-\(UUID().uuidString).json"), options: .atomic)
        draftWriteTask?.cancel()
        if isDemo { try commit { $0 = next.workspace } }
        else {
            guard let repository else { throw WorkspaceError("资料库不可用。") }
            do { try migrationJournal.apply(next, previous: previous, saveWorkspace: { try repository.save($0) }, saveDrafts: { try self.draftRepository.save($0) }, saveReview: { try self.reviewRepository.save($0) }) }
            catch let error as MigrationRestoreFailure {
                if error.recoveryRequired { startupError = error.localizedDescription }
                throw error
            }
            workspace = next.workspace; savedAt = Date()
            notifications.refresh(workspace: workspace, demo: false)
        }
        recordDrafts = next.drafts.filter { !$0.alreadySaved(in: workspace) }; draftSavedAt = Date(); draftNeedsWrite = false; draftError = nil
        adoptReviewDraft(next.review)
        resetBrowsing(); clearTaskUndo(); selection = nil; projectFilter = nil; restoreCollapsed()
        notice = "正式内容与草稿已恢复；恢复前的迁移备份保存在 Backups 文件夹。"

    }

}

extension AppStore {
    func chooseMaterialFiles(_ panel: NSOpenPanel, completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        guard !fileDialogPending else { return false }
        fileDialogPending = true
        if DialogPresentation.chooseFile(panel, fromEditor: true, completion: { [weak self] response in
            self?.fileDialogPending = false
            if response == .OK { completion(panel.urls) }
        }) { return true }
        fileDialogPending = false
        return false
    }

    func exportReview() {
        guard !fileDialogPending, !reviewText.isEmpty else { return }
        let text = reviewText + (reviewReport?.sourceAppendix ?? "")
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]; panel.nameFieldStringValue = "脉络回顾-\(fileDate(Date())).md"; panel.allowsOtherFileTypes = true
        fileDialogPending = true
        if !DialogPresentation.chooseFile(panel, completion: { [weak self] response in
            guard let self else { return }; defer { self.fileDialogPending = false }
            guard response == .OK, let url = panel.url else { return }
            do { try Data(text.utf8).write(to: url, options: .atomic); self.notice = "回顾已导出。" } catch { self.error = error.localizedDescription }
        }) { fileDialogPending = false }
    }
}

func shortDate(_ date: Date) -> String {
    let style = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits) : Date.FormatStyle.dateTime.year().month(.twoDigits).day(.twoDigits)
    return date.formatted(style.locale(Locale(identifier: "zh_CN")))
}
func fullDate(_ date: Date) -> String { date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) }
func fileDate(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: date)
}
func projectColor(_ index: Int) -> Color {
    let rgb = RouteColors.rgb(index)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func channel(_ value: Double) -> Double { dark ? min(1, 0.22 + value * 0.95) : value }
        return NSColor(srgbRed: channel(rgb.0), green: channel(rgb.1), blue: channel(rgb.2), alpha: 1)
    })
}

// Future integrations receive value snapshots and propose edits through the same
// validated save methods. They never get a live persistence context or credentials.
protocol AssistantProvider: Sendable {
    func propose(input: String, context: Workspace) async throws -> AssistantProposal
}
struct AssistantProposal: Sendable { var summary: String; var records: [WorkRecord] }
protocol CalendarAdapter: Sendable { func readEvents(from: Date, to: Date) async throws -> [WorkRecord] }
