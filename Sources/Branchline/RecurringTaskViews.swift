import SwiftUI
import ProgressCore

extension AppStore {
    func refreshRecurringTasks() {
        guard startupError == nil, editor == nil, !quickIsDirty, !fileDialogPending else { return }
        do { var next = workspace; if try next.materializeTaskPlans() { try commit { $0 = next } } }
        catch { notice = "重复任务补排未完成：" + error.localizedDescription }
    }
    func stopRecurringTask(_ id: UUID) {
        do { try commit { try $0.stopTaskPlan(id) }; notice = "已停止后续重复，未来未完成安排已归档。" }
        catch { self.error = error.localizedDescription }
    }
}

struct TaskRepeatFields: View {
    var store: AppStore
    @Binding var item: WorkRecord
    @Binding var scope: RecurrenceScope
    var body: some View {
        if let id = item.taskSeriesID, let plan = store.workspace.taskPlans?.first(where: { $0.id == id }) {
            Section("重复任务") {
                if scope == .following && plan.active {
                    Picker("后续重复", selection: Binding<RepeatRule>(get: { item.taskRepeatRule ?? plan.rule }, set: { item.taskRepeatRule = $0 })) { ForEach(RepeatRule.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Toggle("设置结束日期", isOn: Binding(get: { item.taskRepeatUntil != nil }, set: { item.taskRepeatUntil = $0 ? Calendar.current.date(byAdding: .day, value: 31, to: item.dueAt ?? item.startAt) : nil }))
                    if item.taskRepeatUntil != nil { DatePicker("重复至", selection: Binding(get: { Calendar.current.date(byAdding: .day, value: -1, to: item.taskRepeatUntil!)! }, set: { item.taskRepeatUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) }), displayedComponents: .date) }
                    Text("调整本次及之后未完成的任务，保留已完成内容与未修改的单次补充。").font(.caption).foregroundStyle(.secondary)
                } else { LabeledContent("重复方式", value: plan.rule.title + (plan.active ? " · 本次独立完成" : (store.workspace.taskPlans?.contains { ($0.familyID ?? $0.id) == (plan.familyID ?? plan.id) && $0.active } == true ? " · 后续已调整" : " · 已停止"))) }
                if let date = item.taskOccurrence { LabeledContent("本次计划", value: fullDate(date)) }
                if plan.active {
                    Button("停止后续重复") { if EditorProtection.shared.resolve() { store.editor = nil; store.stopRecurringTask(id) } }.disabled(store.fileDialogPending)
                }
            }
        } else if store.workspace.record(item.id) == nil {
            DisclosureGroup("重复 · \((item.taskRepeatRule ?? .none).title)") {
                Picker("重复方式", selection: Binding<RepeatRule>(get: { item.taskRepeatRule ?? .none }, set: { value in item.taskRepeatRule = value == .none ? nil : value; if value == .none { item.taskRepeatUntil = nil } })) { ForEach(RepeatRule.allCases, id: \.self) { Text($0.title).tag($0) } }
                if item.taskRepeatRule != nil {
                    Toggle("设置结束日期", isOn: Binding(get: { item.taskRepeatUntil != nil }, set: { value in
                        item.taskRepeatUntil = value ? Calendar.current.date(byAdding: .day, value: 31, to: Calendar.current.startOfDay(for: Date())) : nil
                    }))
                    if item.taskRepeatUntil != nil {
                        DatePicker("重复至", selection: Binding(get: { Calendar.current.date(byAdding: .day, value: -1, to: item.taskRepeatUntil!)! }, set: { item.taskRepeatUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) }), displayedComponents: .date)
                    }
                }
            }.help("每次生成独立任务。运行时补排未来一个月，月度计划补排两个月；列表按系列合并。")
        }
    }
}

struct RecordSeriesGroup: Identifiable {
    var id: UUID
    var series: Bool
    var records: [WorkRecord]
    static func groups(_ records: [WorkRecord], workspace: Workspace) -> [RecordSeriesGroup] {
        var result: [RecordSeriesGroup] = [], index: [UUID: Int] = [:]
        for record in records {
            let id = workspace.taskFamilyID(for: record) ?? record.id
            if let i = index[id] { result[i].records.append(record) }
            else { index[id] = result.count; result.append(RecordSeriesGroup(id: id, series: record.taskSeriesID != nil, records: [record])) }
        }
        return result
    }
}
