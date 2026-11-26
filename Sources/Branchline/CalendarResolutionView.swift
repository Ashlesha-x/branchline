import SwiftUI
import ProgressCore

struct CalendarResolutionRequest: Identifiable {
    let id = UUID()
    var item: CalendarImportItem
    var record: WorkRecord
}

struct CalendarResolutionView: View {
    var store: AppStore
    var request: CalendarResolutionRequest
    var completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @LocalState private var choices: [CalendarField: CalendarSide] = [:]
    @LocalState private var reminderChoice: CalendarReminderChoice?
    @LocalState private var resume = false
    @LocalState private var rebind = false
    @LocalState private var message = ""
    private var local: CalendarEventValue { CalendarEventValue(request.record) }
    private var conflicts: [CalendarField] { store.workspace.calendarConflictingFields(request.item) }
    private var fields: [CalendarField] { CalendarField.allCases.filter { !$0.equal(local, request.item.value) } }
    private var moved: Bool { [CalendarField.start, .end].contains { choices[$0] == .calendar && !$0.equal(local, request.item.value) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("处理日历差异").font(.title3.weight(.semibold)); Spacer(); Button("取消") { dismiss() } }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(request.record.title).font(.headline)
                    if request.record.kind != .meeting || request.record.repeatRule != .none {
                        Text("这条记录已改变类型或在 App 内设置重复，请先恢复为普通会议再同步。").foregroundStyle(.orange)
                    }
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(field.rawValue).fontWeight(.medium); if conflicts.contains(field) { Text("两边均有修改").font(.caption).foregroundStyle(.orange) } }
                            HStack(alignment: .top, spacing: 20) {
                                valueColumn("脉络", field.value(local))
                                valueColumn("Apple 日历", field.value(request.item.value))
                            }
                            Picker("\(field.rawValue)取值", selection: Binding<CalendarSide?>(get: { choices[field] }, set: { choices[field] = $0 })) {
                                Text("请选择").tag(CalendarSide?.none)
                                ForEach(CalendarSide.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                            }.frame(maxWidth: 350)
                        }
                        Divider()
                    }
                    if moved && !request.record.reminderDates.isEmpty {
                        Picker("固定提醒", selection: $reminderChoice) {
                            Text("请选择").tag(CalendarReminderChoice?.none)
                            ForEach(CalendarReminderChoice.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                        }
                    }
                    if let a = request.record.calendarLink?.calendarID, let b = request.item.calendarID, a != b { Toggle("将会议重新关联到所选日历", isOn: $rebind) }
                    if request.record.calendarLink?.disposition == .cancelled { Toggle("恢复会议与后续提醒", isOn: $resume) }
                    if store.calendarService.invalidated { Text("日历来源已变化，请关闭后重新读取。").foregroundStyle(.orange) }
                    if !message.isEmpty { Text(message).foregroundStyle(.red) }
                }.padding(20)
            }
            Divider()
            HStack { Spacer(); Button("保存处理结果") { save() }.buttonStyle(.borderedProminent).disabled(store.calendarService.invalidated || !conflicts.allSatisfy { choices[$0] != nil } || (moved && !request.record.reminderDates.isEmpty && reminderChoice == nil) || request.record.kind != .meeting || request.record.repeatRule != .none) }.padding(18)
        }.frame(width: 740, height: min(660, max(380, CGFloat(fields.count) * 170 + 160)))
            .onAppear {
                guard let baseline = request.record.calendarLink?.lastImported else { return }
                for field in fields where !conflicts.contains(field) { choices[field] = field.equal(local, baseline) ? .calendar : .local }
            }
    }
    private func valueColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value.isEmpty ? "（空）" : value).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func save() {
        do {
            try store.commit { try $0.resolveCalendar(request.item, expected: request.record, choices: choices, reminders: reminderChoice, resume: resume, rebind: rebind) }
            completed(); dismiss()
        } catch { message = error.localizedDescription }
    }
}
