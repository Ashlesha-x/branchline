import SwiftUI
import AppKit
import ProgressCore

extension AppStore {
    var reviewConditionsChanged: Bool {
        guard let report = reviewReport else { return false }
        if report.style != reviewDraft.selectedFormat { return true }
        if let scope = report.scope { return !scope.matches(from: reviewFrom, through: reviewThrough, projectID: reviewProjectID, branchID: reviewBranchID) }
        // Old saved reviews retain their original title even without scope metadata.
        let scope = workspace.branch(reviewBranchID)?.title ?? workspace.project(reviewProjectID)?.title ?? "全部项目与独立分支"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return report.title != "\(scope) · \(f.string(from: reviewFrom)) 至 \(f.string(from: reviewThrough))"
    }
    func openReview() {
        editor = nil; guard editor == nil else { return }
        browse { mainPage = .review; search = ""; searchPanelVisible = false; selection = nil }
        if reviewReport == nil { reviewProjectID = projectFilter }
    }
    func generateReview() {
        reviewDraft.refreshPresetDates()
        do {
            let result = try workspace.review(from: reviewFrom, through: reviewThrough, projectID: reviewProjectID, branchID: reviewBranchID, format: reviewDraft.selectedFormat)
            if reviewDraft.hasManualChanges && !confirmReviewReplacement("替换手动修改的回顾？") { return }
            reviewDraft.replace(with: result); flushReviewDraft()
        }
        catch { self.error = error.localizedDescription }
    }
    private func confirmReviewReplacement(_ title: String, undoing: Bool = false) -> Bool {
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = undoing ? "当前文字已手动修改，恢复将替换这些文字。" : "当前文字已手动修改。替换后可撤销本次重新生成。"
        alert.addButton(withTitle: "保留当前文字").keyEquivalent = "\r"
        alert.addButton(withTitle: "替换")
        return DialogPresentation.confirm(alert) == .alertSecondButtonReturn
    }
    func undoReviewGeneration() {
        guard reviewDraft.previous != nil else { return }
        if reviewDraft.hasManualChanges && !confirmReviewReplacement("恢复重新生成前的文字？", undoing: true) { return }
        reviewDraft.undoReplacement(); flushReviewDraft()
    }
    func openReviewLink(_ url: URL) {
        if url.scheme == "branchline" { openSourceURL(url) }
        else if url.scheme == "mailto" { NSWorkspace.shared.open(url) }
        else { openMaterial(url) }
    }
    func openSourceURL(_ url: URL) {
        guard url.scheme == "branchline", let kind = url.host, let id = UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), !fileDialogPending else { return }
        let occurrence = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "occurrence" }?.value.flatMap(Double.init).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        guard (kind == "record" && workspace.record(id) != nil) || (kind == "merge" && workspace.merges.contains { $0.id == id }) else { notice = "当前空间中找不到这条来源，内容可能已删除或属于其他空间。"; return }
        guard EditorProtection.shared.resolve() else { return }
        browse {
            endQuickProgress(); editor = nil; mainPage = .projects; search = ""; searchPanelVisible = false; projectFilter = nil
            mode = .timeline
            if kind == "merge", let merge = workspace.merges.first(where: { $0.id == id }) { selection = .merge(id); moveTo(merge.date) }
            else if let record = workspace.record(id) { selection = .record(id); selectedOccurrence = occurrence; moveTo(occurrence ?? record.startAt) }
        }
    }

}

struct ReviewView: View {
    @Bindable var store: AppStore
    @LocalState private var editing = false
    @LocalState private var showsOptions = false
    @LocalState private var sourceVisibility: Bool?
    private var hasSources: Bool { store.reviewReport?.sections.contains { !$0.entries.isEmpty } == true }
    private var showsSources: Bool { hasSources && (sourceVisibility ?? (store.reviewReport?.style == .detailed)) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.vertical, 10)
            reviewContext
            Divider()
            HSplitView {
                Group {
                    if editing {
                        TextEditor(text: $store.reviewText).font(.body).padding(14).accessibilityIdentifier("reviewText")
                    } else {
                        ReviewMarkdownView(markdown: store.reviewText, openLink: store.openReviewLink)
                            .frame(maxWidth: showsSources ? .infinity : 860)
                            .frame(maxWidth: .infinity)
                    }
                }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                if showsSources { sourcesPane.frame(minWidth: 220, idealWidth: 265, maxWidth: 340) }
            }
            if !store.reviewSaveStatus.isEmpty && !store.isDemo {
                HStack { Text(store.reviewSaveStatus).font(.caption).foregroundStyle(store.reviewReadFailed || store.reviewSaveStatus.contains("失败") ? Color.red : Color.secondary); Spacer() }.padding(.horizontal, 18).padding(.vertical, 6)
            }
        }.task {
            store.reviewDraft.refreshPresetDates()
            if store.reviewReport == nil && store.reviewText.isEmpty { store.generateReview() }
        }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in store.reviewDraft.refreshPresetDates() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.reviewDraft.refreshPresetDates() }
            .onDisappear { store.flushReviewDraft() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("周期", selection: Binding(get: { store.reviewPreset }, set: { value in
                store.reviewPreset = value
                store.reviewDraft.refreshPresetDates()
                if value == .custom { showsOptions = true }
            })) {
                ForEach(ReviewPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().accessibilityLabel("回顾周期").frame(width: 78)
            Picker("项目", selection: Binding(get: { store.reviewProjectID }, set: { value in
                store.reviewProjectID = value
                store.reviewBranchID = nil
            })) {
                Text("全部项目与独立分支").tag(UUID?.none)
                ForEach(store.workspace.projects) { Text($0.title).tag(Optional($0.id)) }
            }.labelsHidden().accessibilityLabel("回顾项目").frame(width: 161)
            Button { showsOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("回顾选项：分支、日期和格式").accessibilityLabel("回顾选项")
                .popover(isPresented: $showsOptions, arrowEdge: .bottom) { options }
            Spacer(minLength: 4)
            Picker("正文显示", selection: $editing) { Text("阅读").tag(false); Text("编辑").tag(true) }
                .pickerStyle(.segmented).labelsHidden().accessibilityLabel("正文显示").frame(width: 106)
            Button { sourceVisibility = !showsSources } label: { Label("来源", systemImage: "sidebar.right") }
                .disabled(!hasSources).help(showsSources ? "隐藏来源" : "显示来源").accessibilityLabel(showsSources ? "隐藏来源" : "显示来源")
            Menu("复制与导出") {
                Button("复制文字") { copyReview() }
                Button("导出 Markdown…") { store.exportReview() }.disabled(store.fileDialogPending)
            }.fixedSize().disabled(store.reviewText.isEmpty)
            Button(store.reviewReport == nil ? "生成回顾" : "重新生成") { store.generateReview() }
                .help("按当前条件重新整理来源，并替换正文")
        }
    }

    private var options: some View {
        Form {
            Picker("分支", selection: $store.reviewBranchID) {
                Text("全部归属").tag(UUID?.none)
                ForEach(store.workspace.branches.filter { store.reviewProjectID == nil || $0.projectIDs.contains(store.reviewProjectID!) }) { Text($0.title).tag(Optional($0.id)) }
            }
            Picker("格式", selection: Binding(get: { store.reviewDraft.selectedFormat }, set: { store.reviewDraft.format = $0 })) {
                ForEach(ReviewFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.accessibilityLabel("回顾格式")
            DatePicker("开始日期", selection: Binding(get: { store.reviewFrom }, set: { store.reviewFrom = $0; store.reviewPreset = .custom }), displayedComponents: .date)
            DatePicker("结束日期", selection: Binding(get: { store.reviewThrough }, set: { store.reviewThrough = $0; store.reviewPreset = .custom }), displayedComponents: .date)
            if store.reviewDraft.previous != nil {
                Divider()
                Button("撤销重新生成") { showsOptions = false; store.undoReviewGeneration() }
            }
        }.padding(16).frame(width: 288)
    }

    @ViewBuilder private var reviewContext: some View {
        let changed = store.reviewConditionsChanged
        if changed || editing || store.reviewPreset == .custom || store.reviewBranchID != nil {
            VStack(alignment: .leading, spacing: 3) {
                if changed {
                    Label("条件已变化，正文尚未更新", systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange).accessibilityIdentifier("reviewConditionsChanged")
                }
                if changed || store.reviewPreset == .custom || store.reviewBranchID != nil {
                    let dates = "\(shortDate(store.reviewFrom))–\(shortDate(store.reviewThrough))"
                    Text("已选：" + ([store.workspace.branch(store.reviewBranchID)?.title, dates, store.reviewDraft.selectedFormat.rawValue].compactMap { $0 }).joined(separator: " · "))
                }
                if let report = store.reviewReport, changed || editing {
                    Text("正文范围：" + report.title + " · " + report.style.rawValue)
                }
            }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 9)
        }
    }

    private var sourcesPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("来源").font(.headline)
                if let report = store.reviewReport {
                    ForEach(report.sections.filter { !$0.entries.isEmpty }) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text((section.group.map { $0.title + " · " } ?? "") + section.title).font(.caption).foregroundStyle(.secondary)
                            ForEach(section.entries) { entry in
                                Button { if let url = URL(string: entry.sourceURL) { store.openSourceURL(url) } } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.title).lineLimit(2)
                                            if let date = entry.occurrence ?? entry.date {
                                                let record = store.workspace.record(entry.entityID)
                                                Text(WorkDateText.date(date, timed: entry.occurrence != nil || record?.dateOnly == false, zone: record?.timeZoneID ?? TimeZone.current.identifier))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(); Image(systemName: "arrow.up.right").font(.caption)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("查看回顾来源：" + entry.title + (entry.date.map { "，" + fullDate($0) } ?? ""))
                            }
                        }
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyReview() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReviewMarkdown.render(store.reviewText).string.replacingOccurrences(of: "\u{2028}", with: "\n"), forType: .string)
        store.notice = "回顾文字已复制。"
    }
}
