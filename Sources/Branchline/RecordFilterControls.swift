import SwiftUI
import ProgressCore

struct RecordFilterButton: View {
    @Bindable var store: AppStore
    @LocalState private var showing = false
    var body: some View {
        Button {
            if store.mode != .list || store.mainPage != .projects || !store.search.isEmpty { store.browse { store.searchPanelVisible = true } }
            showing = true
        } label: { Image(systemName: store.recordFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
            .accessibilityLabel("组合筛选").help("筛选搜索与列表")
            .popover(isPresented: $showing) { RecordFilterControls(store: store) }
    }
}

struct RecordFilterControls: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("组合筛选").font(.headline)
            Form {
                Picker("项目", selection: Binding(get: { store.projectFilter }, set: { value in store.browse { store.projectFilter = value; store.recordFilter.branchID = nil } })) {
                    Text("全部项目与独立分支").tag(UUID?.none)
                    ForEach(store.workspace.projects) { Text($0.title).tag(Optional($0.id)) }
                }
                Picker("分支", selection: $store.recordFilter.branchID) {
                    Text("全部归属").tag(UUID?.none)
                    ForEach(store.workspace.branches.filter { store.projectFilter == nil || $0.projectIDs.contains(store.projectFilter!) }) { branch in
                        Text(branch.title + (branch.projectIDs.isEmpty ? " · 独立" : "")).tag(Optional(branch.id))
                    }
                }.help("选择分支时只查看该分支的直接内容。")
                Picker("任务状态", selection: $store.recordFilter.taskStatus) {
                    Text("全部内容").tag(WorkStatus?.none)
                    ForEach(WorkStatus.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                Picker("日期依据", selection: $store.recordFilter.dateField) { ForEach(RecordDateField.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .help("未安排计划开始的任务没有发生日期，可按截止、完成或录入日期查找。")
                Toggle("限定日期范围", isOn: Binding(get: { store.recordFilter.from != nil || store.recordFilter.through != nil }, set: { value in
                    store.recordFilter.from = value ? Calendar.current.date(byAdding: .day, value: -7, to: Date()) : nil
                    store.recordFilter.through = value ? Date() : nil
                }))
                if store.recordFilter.from != nil || store.recordFilter.through != nil {
                    DatePicker("从", selection: Binding(get: { store.recordFilter.from ?? Date() }, set: { store.recordFilter.from = $0 }), displayedComponents: .date)
                    DatePicker("至", selection: Binding(get: { store.recordFilter.through ?? Date() }, set: { store.recordFilter.through = $0 }), displayedComponents: .date)
                    if let from = store.recordFilter.from, let through = store.recordFilter.through, Calendar.current.startOfDay(for: from) > Calendar.current.startOfDay(for: through) { Text("开始日期不能晚于结束日期。").foregroundStyle(.red) }
                }
            }.formStyle(.columns).fixedSize(horizontal: false, vertical: true)
            Button("清除筛选") { store.browse { store.recordFilter = RecordFilter(); store.projectFilter = nil } }
        }.padding(16).frame(width: 390).fixedSize(horizontal: false, vertical: true)
            .onChange(of: store.recordFilter) { _, _ in
                store.searchEntityFilter = nil
                if store.recordFilter.taskStatus != nil { store.listKind = RecordKind.task.rawValue }
            }
    }
}

struct ActiveRecordFilters: View {
    var store: AppStore
    private var summary: String {
        var values: [String] = []
        if let status = store.recordFilter.taskStatus { values.append(status.title) }
        if let project = store.workspace.project(store.projectFilter) { values.append(project.title) }
        if let branch = store.workspace.branch(store.recordFilter.branchID) { values.append(branch.title) }
        let filter = store.recordFilter
        if filter.from != nil || filter.through != nil {
            values.append(filter.dateField.rawValue + "：" + (filter.from.map(shortDate) ?? "不限") + "—" + (filter.through.map(shortDate) ?? "不限"))
        } else if filter.dateField != .occurrence { values.append(filter.dateField.rawValue) }
        return values.joined(separator: " · ")
    }
    var body: some View {
        if !summary.isEmpty {
            HStack(spacing: 10) {
                Text(summary).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                Button("清除筛选") { store.browse { store.recordFilter = RecordFilter(); store.projectFilter = nil } }.buttonStyle(.plain).foregroundStyle(.tint)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8).accessibilityIdentifier("activeRecordFilters")
            Divider()
        }
    }
}
