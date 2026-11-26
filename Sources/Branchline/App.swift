import SwiftUI
import AppKit
import ProgressCore

// macOS 27 exposes both a State macro and the established property wrapper.
// Use the wrapper explicitly so Command Line Tools do not need Xcode's macro plugin.
typealias LocalState<Value> = SwiftUI.State<Value>

final class AppDelegate: NSObject, NSApplicationDelegate {
    var sourceURLHandler: ((URL) -> Void)?
    var pendingSourceURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler = sourceURLHandler { urls.forEach(handler) } else { pendingSourceURLs += urls }
    }
    func installSourceURLHandler(_ handler: @escaping (URL) -> Void) {
        sourceURLHandler = handler; let pending = pendingSourceURLs; pendingSourceURLs = []; pending.forEach(handler)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { EditorProtection.shared.prepareForTermination() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { DialogPresentation.install(); NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true) }
}

@main struct BranchlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.openWindow) private var openWindow
    @LocalState private var store = AppStore()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        Window("脉络", id: "main") {
            MainView(store: store)
                .onAppear {
                    delegate.installSourceURLHandler { url in openWindow(id: "main"); store.openSourceURL(url); NSApp.activate(ignoringOtherApps: true) }
                    store.notifications.installOpenHandler { [weak store = store] target in
                        guard let store else { return }
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                        if store.isDemo {
                            do { try store.switchSpace(demo: false) }
                            catch { store.error = error.localizedDescription }
                        }
                        if !store.isDemo { store.openReminder(target) }
                    }
                }
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.checkAutomaticICloudBackup()
                    if !store.isDemo { store.notifications.refresh(workspace: store.workspace, demo: false) }
                }
        }
        .defaultSize(width: 1420, height: 860)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出脉络") { EditorProtection.shared.quit() }.keyboardShortcut("q")
            }
            CommandGroup(replacing: .newItem) {
                Button("新建进度记录") { store.newRecord() }.keyboardShortcut("n")
                Button("新建项目") { store.editor = .project(Project()) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("新建分支") { store.editor = .branch(Branch(projectIDs: store.projectFilter.map { [$0] } ?? [])) }
            }
            CommandGroup(after: .importExport) {
                Button("导出完整备份…") { store.exportBackup() }
                Button("从备份恢复…") { store.importBackup() }
            }
            CommandGroup(replacing: .appSettings) { Button("设置与数据") { openWindow(id: "main"); store.openSettings(); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(",") }
        }
        MenuBarExtra("脉络", systemImage: "point.3.connected.trianglepath.dotted") { QuickPanel(store: store).preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light).environment(\.locale, Locale(identifier: "zh_CN")) }
            .menuBarExtraStyle(.window)
    }
}

struct MainView: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("inspectorWidth") private var inspectorWidth = 340.0
    @AppStorage("canvasSidebarHidden") private var canvasSidebarHidden = false
    @LocalState private var mainWidth: CGFloat = 1420
    private var showsProjectCanvas: Bool {
        store.mainPage == .projects && !store.isSearching && store.mode != .list &&
        (!store.workspace.projects.isEmpty || !store.workspace.branches.isEmpty)
    }
    private var sidebarWidth: CGFloat { showsProjectCanvas && canvasSidebarHidden ? 0 : 205 }
    private var maximumInspectorWidth: CGFloat { max(260, min(560, mainWidth - sidebarWidth - 486)) }
    var body: some View {
        Group {
            if let error = store.startupError {
                ContentUnavailableView { Label("资料库未能打开", systemImage: "externaldrive.badge.exclamationmark") } description: { Text(error).textSelection(.enabled) } actions: {
                    Button("查看数据位置") { NSWorkspace.shared.open(store.dataDirectory) }
                }
            } else {
                HStack(spacing: 0) {
                    if sidebarWidth > 0 {
                        Sidebar(store: store).frame(width: sidebarWidth)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        topBar
                        Divider()
                        if store.editor == nil { DraftRecoveryBar(store: store) }
                        if store.quickVisible, store.quickRecord != nil {
                            QuickProgressComposer(store: store, surface: .main).padding(16).background(Color.primary.opacity(0.025))
                            Divider()
                        }
                        if store.showingReview { ReviewView(store: store).id(store.browseSpaceToken) }
                        else if store.showingSettings { SettingsPanel(store: store).id(store.browseSpaceToken) }
                        else if store.showingTrash { TrashPanel(store: store).id(store.browseSpaceToken) }
                        else if store.workspace.projects.isEmpty && store.workspace.branches.isEmpty { welcome }
                        else {
                            HStack(spacing: 0) {
                                VStack(spacing: 0) {
                                    if store.isSearching {
                                        SearchResultsView(store: store).id(store.browseSpaceToken)
                                    } else if store.showingAgenda { AgendaView(store: store).id(store.browseSpaceToken) }
                                    else if store.mode == .list { RecordList(store: store).id(store.browseSpaceToken) }
                                    else if store.mode == .graph { RoadmapView(store: store).id(store.browseSpaceToken) }
                                    else { TimelineView(store: store).id(store.browseSpaceToken) }
                                }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .onGeometryChange(for: CGSize.self) { $0.size } action: { store.browseWindowSize = $0 }
                                if store.selection != nil && (!store.isSearching || store.searchHits.contains { $0.id == store.selectedEntityID && (store.searchEntityFilter == nil || $0.kind == store.searchEntityFilter) }) {
                                    InspectorResizeHandle(width: $inspectorWidth, maximum: maximumInspectorWidth)
                                    Inspector(store: store).id(store.browseSpaceToken).frame(width: min(inspectorWidth, maximumInspectorWidth))
                                }
                            }
                        }
                        Divider()
                        HStack {
                            Circle().fill(Color.teal).frame(width: 6, height: 6)
                            Text(store.isDemo ? "示例内容 · 本次体验有效" : "本地保存 · \(store.workspace.records.count) 条记录")
                            if let saved = store.savedAt { Text("· \(saved.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN"))))") }
                            Spacer()
                            if let action = store.taskUndo {
                                Text("已完成：" + action.before.title).lineLimit(1)
                                Button("撤销完成") { store.undoAgendaCompletion() }.accessibilityIdentifier("undoTaskCompletion")
                            }
                            if store.iCloudBackupFailed && !store.isDemo {
                                Button("iCloud 备份未完成") { store.openSettings() }.buttonStyle(.plain).foregroundStyle(.orange).help(store.iCloudBackupMessage)
                            }
                            if let id = store.recentDeletionID, store.workspace.trash.contains(where: { $0.id == id }) { Button("撤销删除") { store.restoreDeletion(id) } }
                            if !store.notice.isEmpty { Text(store.notice).lineLimit(1); Button { store.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示") }
                        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
                    }
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 690)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { mainWidth = $0.width }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MainWindowProtection())
        .onChange(of: store.selection) { _, _ in store.refreshQuickContext() }
        .onChange(of: store.projectFilter) { _, _ in store.refreshQuickContext() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in store.flushDrafts(); store.flushReviewDraft() }
        .onReceive(NotificationCenter.default.publisher(for: .editorWindowClosing)) { _ in store.endQuickProgress(); store.editor = nil }
        .sheet(isPresented: $store.showingCalendar) { CalendarImportView(store: store) }
        .sheet(item: $store.editor) { route in
            switch route {
            case .project(let p): ProjectEditor(store: store, initial: p)
            case .branch(let b): BranchEditor(store: store, initial: b)
            case .record(let r): RecordEditor(store: store, initial: r)
            case .progressDraft(let r, let dirty): RecordEditor(store: store, initial: r, startsDirty: dirty)
            case .recurring(let r, let edit): RecordEditor(store: store, initial: r, recurrence: edit)
            case .merge(let id): MergeEditor(store: store, branchID: id)
            case .restoredDraft(let draft): RecordEditor(store: store, initial: draft.record, recurrence: RecurringEdit(draft.recurrenceForRecovery(in: store.workspace)), draft: draft)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if showsProjectCanvas {
                    let title = canvasSidebarHidden ? "显示项目侧栏" : "隐藏项目侧栏"
                    Button { canvasSidebarHidden.toggle() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
                }
                if !store.showingUtilityPage {
                    HStack(spacing: 8) {
                        Button { store.browseBack() } label: { Image(systemName: "chevron.left") }.disabled(!store.canBrowseBack).help("返回上一项（⌘[）").accessibilityLabel("返回上一项").keyboardShortcut("[", modifiers: .command)
                        Button { store.browseForward() } label: { Image(systemName: "chevron.right") }.disabled(!store.canBrowseForward).help("前进到下一项（⌘]）").accessibilityLabel("前进到下一项").keyboardShortcut("]", modifiers: .command)
                    }.buttonStyle(.plain)
                }
                Text(store.showingSettings ? "设置与数据" : store.showingTrash ? "回收站" : store.showingReview ? "回顾" : store.isSearching ? "搜索" : store.showingAgenda ? "待办" : store.workspace.project(store.projectFilter)?.title ?? "全部项目").font(.title3.weight(.semibold)).lineLimit(1)
                if store.isDemo { Label("示例", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary).help("示例空间的修改仅在本次运行保留，不会写入个人空间。可从侧栏切换空间。") }
                Spacer(minLength: 12)
                if store.editor == nil && store.draftRecoveryCollapsed && !store.recoverableDrafts.isEmpty {
                    Menu("草稿 \(store.recoverableDrafts.count)") {
                        ForEach(store.recoverableDrafts) { draft in Button(draft.record.title.isEmpty ? draft.record.kind.title : draft.record.title) { store.resumeDraft(draft) } }
                        Divider()
                        Button("展开草稿提示") { store.draftRecoveryCollapsed = false }
                    }.fixedSize().accessibilityLabel("草稿 \(store.recoverableDrafts.count)")
                }
                if !store.showingUtilityPage && !store.showingReview {
                    TextField("搜索项目、分支、记录与成果", text: $store.search).textFieldStyle(.roundedBorder).frame(width: 225).accessibilityLabel("统一搜索")
                    RecordFilterButton(store: store)
                    if store.isSearching { Button { store.search = ""; store.searchPanelVisible = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
                    Button { store.beginQuickProgress(.main) } label: { Label("记进度", systemImage: "square.and.pencil") }.buttonStyle(.borderedProminent).disabled(store.workspace.projects.isEmpty && store.workspace.branches.isEmpty)
                    Menu {
                        Button("进度记录") { store.newRecord(.progress) }
                        Button("任务 / DDL") { store.newRecord(.task) }
                        Button("会议") { store.newRecord(.meeting) }
                        Divider()
                        Button("项目") { store.editor = .project(Project()) }
                        Button("分支") { store.editor = .branch(Branch(projectIDs: store.projectFilter.map { [$0] } ?? [])) }
                    } label: { Label("新增", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            if !store.showingUtilityPage && !store.showingReview && !store.showingAgenda && !store.isSearching && (!store.workspace.projects.isEmpty || !store.workspace.branches.isEmpty) {
                HStack(spacing: 10) {
                    Picker("视图", selection: Binding(get: { store.mode }, set: { value in store.browse { store.mode = value; store.showingAgenda = false } })) { ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 245)
                    Spacer(minLength: 8)
                    if store.mode == .timeline { timelineControls }
                    if store.mode == .graph {
                        Menu("显示") {
                            ForEach(store.visibleProjects) { project in
                                Button("\(store.isCollapsed(project.id, in: .graph) ? "展开" : "折叠") · \(project.title)") { store.toggleCollapsed(project.id, in: .graph) }
                            }
                            if !store.expandedFutureTaskSeries.isEmpty || !store.expandedGraphRows.isEmpty || store.pinnedRelationID != nil {
                                Divider()
                                if !store.expandedFutureTaskSeries.isEmpty { Button("收起远期重复") { store.expandedFutureTaskSeries.removeAll() } }
                                if !store.expandedGraphRows.isEmpty { Button("收起节点") { store.expandedGraphRows.removeAll() } }
                                if store.pinnedRelationID != nil { Button("取消固定连线") { store.pinnedRelationID = nil } }
                            }
                        }.fixedSize().accessibilityLabel("脉络图显示选项")
                    }
                }.controlSize(.small)
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    private var timelineControls: some View {
        HStack(spacing: 8) {
            Button { store.moveTo(Calendar.current.date(byAdding: .month, value: -1, to: store.focusDate)!) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上个月")
            DatePicker("定位日期", selection: $store.focusDate, displayedComponents: .date).labelsHidden().onChange(of: store.focusDate) { _, _ in store.navigationToken = UUID() }.fixedSize()
            Button { store.moveTo(Calendar.current.date(byAdding: .month, value: 1, to: store.focusDate)!) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下个月")
            Button("今天") { store.moveTo(Date()) }
            Picker("时间尺度", selection: $store.dayWidth) { Text("日").tag(140.0); Text("周").tag(88.0); Text("月").tag(48.0) }.labelsHidden().frame(width: 66)
        }
    }
    private var welcome: some View {
        VStack(spacing: 22) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 46, weight: .light)).foregroundStyle(.blue)
            Text("从第一条工作线索开始").font(.title2.weight(.medium))
            Text("创建项目，分出探索方向，记录每一步进展。").multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 12) { Button("创建第一个项目") { store.editor = .project(Project()) }.buttonStyle(.borderedProminent); Button("体验示例空间") { switchSpace(true) } }
            Button("从已有备份恢复…") { store.importBackup() }.buttonStyle(.link)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func switchSpace(_ demo: Bool) { do { try store.switchSpace(demo: demo) } catch { store.error = error.localizedDescription } }
}

struct Sidebar: View {
    @Bindable var store: AppStore
    @LocalState private var hoveredRouteID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("脉络").font(.headline); Spacer(); Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary) }.padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    navRow("待办", symbol: "checklist", selected: store.showingAgenda, color: .orange) { store.browse { store.showingAgenda = true; store.projectFilter = nil; store.selection = nil; store.search = "" } }
                    navRow("回顾", symbol: "doc.text.magnifyingglass", selected: store.showingReview, color: .secondary) { store.openReview() }
                    navRow("回收站", symbol: "trash", selected: store.showingTrash, color: .secondary) { store.openTrash() }
                    navRow("全部项目", symbol: "square.stack.3d.up", selected: store.projectFilter == nil && !store.showingAgenda && !store.showingUtilityPage && !store.showingReview, color: .blue) { store.browse { store.showingAgenda = false; store.projectFilter = nil; store.selection = nil } }
                    Text("项目与独立分支").font(.caption).foregroundStyle(.secondary).padding(.leading, 10).padding(.top, 16).padding(.bottom, 4)
                    ForEach(store.routeLayout(in: .sidebar)) { placement in
                        if let status = placement.groupStatus {
                            RouteStatusButton(store: store, status: status, scope: .sidebar, compact: true).padding(.top, 9)
                        } else if let project = store.workspace.project(placement.id) {
                            projectEntry(project)
                        } else if let branch = store.workspace.branch(placement.id) {
                            branchEntry(branch, placement: placement)
                        }
                    }
                }.padding(.horizontal, 10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Button { store.editor = .project(Project()) } label: {
                    Label("新建项目", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button { store.editor = .branch(Branch()) } label: {
                    Label("新建分支", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Divider()
                Menu {
                    Button("个人空间") { changeSpace(false) }
                    Button("示例空间（独立体验）") { changeSpace(true) }
                } label: { Label(store.isDemo ? "示例空间" : "个人空间", systemImage: store.isDemo ? "sparkles" : "internaldrive") }
                .menuStyle(.borderlessButton)
                navRow("设置与数据", symbol: "gearshape", selected: store.showingSettings, color: .secondary) { store.openSettings() }
            }.padding(18)
        }.background(.bar)
    }
    private func navRow(_ title: String, symbol: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Image(systemName: symbol).foregroundStyle(color); Text(title).lineLimit(1); Spacer(minLength: 0) }.padding(.horizontal, 10).padding(.vertical, 9).background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain)
    }
    private func changeSpace(_ demo: Bool) { do { try store.switchSpace(demo: demo) } catch { store.error = error.localizedDescription } }
    private func projectEntry(_ project: Project) -> some View {
                        HStack(spacing: 5) {
                            Button { store.toggleCollapsed(project.id, in: .sidebar) } label: { Image(systemName: store.isCollapsed(project.id, in: .sidebar) ? "chevron.right" : "chevron.down").font(.caption).frame(width: 14, height: 28) }.buttonStyle(.plain).accessibilityLabel("\(store.isCollapsed(project.id, in: .sidebar) ? "展开" : "折叠")\(project.title)")
                            Button {
                                store.browse { store.showingAgenda = false; store.projectFilter = project.id; store.selection = .project(project.id) }
                            } label: {
                                HStack(spacing: 7) { Image(systemName: "folder.fill").foregroundStyle(projectColor(project.color)); Text(project.title).lineLimit(1); Spacer(minLength: 0) }
                            }.buttonStyle(.plain)
                            Menu {
                                Button("新建进度记录") { store.newRecord(.progress, projectID: project.id) }
                                Button("新建任务 / DDL") { store.newRecord(.task, projectID: project.id) }
                                Button("新建会议") { store.newRecord(.meeting, projectID: project.id) }
                                Divider()
                                Button("拉出新分支") { store.newBranch(projectID: project.id) }
                                Divider()
                                Button("删除项目…", role: .destructive) { store.requestDeletion(.project(project.id)) }
                            } label: {
                                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22, height: 26).contentShape(Rectangle())
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("为「\(project.title)」新建内容").accessibilityLabel("为\(project.title)新建内容")
                                .opacity(hoveredRouteID == project.id || store.projectFilter == project.id ? 1 : 0)
                                .allowsHitTesting(hoveredRouteID == project.id || store.projectFilter == project.id)
                        }.padding(.horizontal, 7).padding(.vertical, 4).background(store.projectFilter == project.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hoveredRouteID = $0 ? project.id : (hoveredRouteID == project.id ? nil : hoveredRouteID) }
            .draggable(project.id.uuidString)
            .dropDestination(for: String.self) { values, point in
                guard let value = values.first, let source = UUID(uuidString: value), store.canReorderRoute(source, relativeTo: project.id) else { return false }
                store.reorderRoute(source, relativeTo: project.id, after: point.y > 18); return true
            }
    }
    private func branchEntry(_ branch: Branch, placement: RoutePlacement) -> some View {
        let owned = placement.ownerProjectID != nil
        return HStack(spacing: 5) {
            navRow(branch.title + (branch.projectIDs.count > 1 ? " · 共享" : ""), symbol: store.branchSymbol(branch.id), selected: store.selection == .branch(branch.id), color: projectColor(branch.color)) {
                store.browse { store.showingAgenda = false; store.projectFilter = placement.ownerProjectID; store.selection = .branch(branch.id); store.moveTo(branch.startAt) }
            }
            branchAddMenu(branch).opacity(hoveredRouteID == branch.id || store.selectedRouteID == branch.id ? 1 : 0).allowsHitTesting(hoveredRouteID == branch.id || store.selectedRouteID == branch.id)
        }.padding(.leading, (owned ? 22 : 0) + CGFloat(min(placement.depth, 4)) * 12).padding(.trailing, 7)
            .onHover { hoveredRouteID = $0 ? branch.id : (hoveredRouteID == branch.id ? nil : hoveredRouteID) }
            .draggable(branch.id.uuidString)
            .dropDestination(for: String.self) { values, point in
                guard let value = values.first, let source = UUID(uuidString: value), store.canReorderRoute(source, relativeTo: branch.id) else { return false }
                store.reorderRoute(source, relativeTo: branch.id, after: point.y > 18); return true
            }
    }
    private func branchAddMenu(_ branch: Branch) -> some View {
        Menu {
            Button("新建进度记录") { store.newRecord(.progress, branchID: branch.id) }
            Button("新建任务 / DDL") { store.newRecord(.task, branchID: branch.id) }
            Button("新建会议") { store.newRecord(.meeting, branchID: branch.id) }
            Divider()
            Button("拉出子分支") { store.newChildBranch(parentID: branch.id) }
            Button("合并阶段成果…") { store.editor = .merge(branch.id) }.disabled(branch.projectIDs.isEmpty && branch.originBranchID == nil)
            Divider()
            Button("删除分支…", role: .destructive) { store.requestDeletion(.branch(branch.id)) }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22, height: 26).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("为「\(branch.title)」新建内容").accessibilityLabel("为分支\(branch.title)新建内容")
    }
}

struct RecordList: View {
    @Bindable var store: AppStore
    private var kind: String { store.listKind }
    var records: [WorkRecord] {
        store.filteredRecords.filter { record in
            var filter = store.recordFilter; filter.projectID = store.projectFilter
            guard filter.matches(record, in: store.workspace) else { return false }
            let ids = store.workspace.projects(for: record)
            let relevant = ids.filter { store.projectFilter == nil || $0 == store.projectFilter }
            let independent = store.projectFilter == nil && record.branchID.map { store.workspace.branchIsIndependent($0) } == true
            let shown = store.recordFilter.isActive || !store.search.isEmpty || ids.isEmpty || independent || relevant.contains { !store.isCollapsed($0, in: .list) }
            let status = store.routeStatus(of: record)
            let groupShown = store.recordFilter.isActive || store.isSearching || status == nil || store.expandedRouteStatuses(in: .list).contains(status!)
            return shown && groupShown && (kind == "all" || record.kind.rawValue == kind)
        }.sorted { (store.recordFilter.dateField.date(of: $0) ?? .distantPast) > (store.recordFilter.dateField.date(of: $1) ?? .distantPast) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("类型", selection: Binding(get: { store.listKind }, set: { value in store.browse { store.listKind = value; store.viewportOffsets["list"] = BrowseOffset(); store.browseRestoreToken = UUID() } })) { Text("全部记录").tag("all"); ForEach(RecordKind.allCases, id: \.self) { Text($0.title).tag($0.rawValue) } }.frame(width: 150)
                Spacer(); Text("\(records.count) 条 · 按\(store.recordFilter.dateField.rawValue)排序").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            ActiveRecordFilters(store: store)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if store.search.isEmpty && !store.recordFilter.isActive {
                            // The control must outlive its collapsed state, including empty projects.
                            ForEach(store.routeLayout(in: .list).compactMap { store.workspace.project($0.id) }.filter { $0.status == .active }, id: \.id.uuidString) { project in
                                projectHeader(project).id(project.id.uuidString)
                            }
                            Divider()
                        }
                        if records.isEmpty {
                            if store.search.isEmpty {
                                ContentUnavailableView("当前没有可显示的记录", systemImage: "text.alignleft", description: Text("可展开上方项目，或切换记录类型。")).frame(minHeight: 180)
                            } else { ContentUnavailableView.search(text: store.search) }
                        }
                        groupedRows(records.filter { store.recordFilter.isActive || store.isSearching || store.routeStatus(of: $0) == nil })
                        if !store.isSearching && !store.recordFilter.isActive {
                            ForEach(RouteGroups.statuses, id: \.self) { status in
                                if !store.routeGroupProjects(status, in: .list).isEmpty {
                                    RouteStatusButton(store: store, status: status, scope: .list).background(Color(nsColor: .controlBackgroundColor))
                                    if store.expandedRouteStatuses(in: .list).contains(status) {
                                        ForEach(store.routeLayout(in: .list).compactMap { store.workspace.project($0.id) }.filter { $0.status == status }) { project in projectHeader(project).id(project.id.uuidString) }
                                        groupedRows(records.filter { store.routeStatus(of: $0) == status })
                                    }
                                }
                            }
                        }
                    }.scrollTargetLayout()
                }.rememberingBrowsePosition(store, surface: "list")
        }.onChange(of: Set(records.map(\.id)), initial: true) { _, ids in closeFilteredDetail(ids) }
            .onChange(of: store.selection) { _, _ in closeFilteredDetail(Set(records.map(\.id))) }
    }
    private func closeFilteredDetail(_ ids: Set<UUID>) {
        guard store.mainPage == .projects, store.mode == .list, !store.isSearching else { return }
        if case .record(let id) = store.selection, !ids.contains(id) { store.selection = nil }
    }
    @ViewBuilder private func groupedRows(_ records: [WorkRecord]) -> some View {
        ForEach(RecordSeriesGroup.groups(records, workspace: store.workspace)) { group in
            if group.series {
                let plan = store.workspace.taskPlans?.filter { plan in (plan.familyID ?? plan.id) == group.id && group.records.contains { $0.taskSeriesID == plan.id } }.sorted { $0.active == $1.active ? $0.anchor > $1.anchor : $0.active }.first
                let sorted = group.records.sorted { ($0.taskOccurrence ?? $0.startAt) < ($1.taskOccurrence ?? $1.startAt) }
                let next = sorted.first { $0.status == .active || $0.status == .paused } ?? sorted.last!
                HStack(spacing: 12) {
                    Button { if !store.expandedTaskSeries.insert(group.id).inserted { store.expandedTaskSeries.remove(group.id) } } label: { Image(systemName: store.expandedTaskSeries.contains(group.id) ? "chevron.down" : "chevron.right").frame(width: 18) }.buttonStyle(.plain).accessibilityLabel("展开重复任务：" + (plan?.prototype.title ?? next.title))
                    Button { store.browse { store.selection = .record(next.id) } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan?.prototype.title ?? next.title).fontWeight(.medium)
                            Text((plan?.rule ?? next.taskRepeatRule ?? .none).title + (plan?.active == false ? " · 已停止" : "") + " · 未完成 \(sorted.filter { $0.status == .active || $0.status == .paused }.count) 次 · 共 \(sorted.count) 次").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(16).id(group.id.uuidString)
                Divider()
                if store.expandedTaskSeries.contains(group.id) { ForEach(sorted) { record in recordRow(record).padding(.leading, 24) } }
            } else if let record = group.records.first { recordRow(record) }
        }
    }
    private func recordRow(_ record: WorkRecord) -> some View {
        Group {
                            Button { store.browse { store.selection = .record(record.id) } } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: record.kind.symbol).frame(width: 25).foregroundStyle(record.status == .completed ? Color.teal : Color.secondary)
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack { Text(record.title).fontWeight(.medium); if record.status != .active { Text(record.status.title).font(.caption).foregroundStyle(.secondary) } }
                                        if !record.body.isEmpty { Text(record.body).lineLimit(2).foregroundStyle(.secondary) }
                                        HStack(spacing: 8) { Text(location(record)); if let due = record.dueAt { Text("DDL \(shortDate(due))").foregroundStyle(CalendarLogic.deadlinePassed(record, now: Date()) ? .red : .secondary) }; if !store.workspace.blockedBy(record).isEmpty { Text("等待依赖").foregroundStyle(.orange) } }.font(.caption)
                                    }
                                    Spacer(); Text((store.recordFilter.dateField.date(of: record) ?? record.taskOccurrence).map(shortDate) ?? "未设置").monospacedDigit().foregroundStyle(.secondary)
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(store.selection == .record(record.id) ? Color.accentColor.opacity(0.08) : .clear)
                            }.buttonStyle(.plain).id(record.id.uuidString)
                            Divider().padding(.leading, 55)
        }
    }
    private func projectHeader(_ project: Project) -> some View {
        let folded = store.isCollapsed(project.id, in: .list)
        let count = store.filteredRecords.filter { store.workspace.projects(for: $0).contains(project.id) && (kind == "all" || $0.kind.rawValue == kind) }.count
        return Button { store.toggleCollapsed(project.id, in: .list) } label: {
            HStack(spacing: 9) {
                Image(systemName: folded ? "chevron.right" : "chevron.down").frame(width: 12)
                Circle().fill(projectColor(project.color)).frame(width: 7, height: 7)
                Text(project.title).lineLimit(1)
                Text(project.status.title).foregroundStyle(.secondary)
                Spacer()
                Text("\(count) 条 · \(folded ? "已折叠" : "已展开")").foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 17).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("列表：\(folded ? "展开" : "折叠")\(project.title)，\(count) 条记录")
    }
    private func location(_ record: WorkRecord) -> String { store.workspace.branch(record.branchID)?.title ?? store.workspace.projects(for: record).compactMap { store.workspace.project($0)?.title }.joined(separator: " · ") }
}
