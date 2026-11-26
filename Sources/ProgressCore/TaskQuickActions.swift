import Foundation

public struct TaskCompletionUndo: Equatable, Sendable {
    public let before: WorkRecord
    public let completed: WorkRecord
    public init(before: WorkRecord, completed: WorkRecord) { self.before = before; self.completed = completed }
}
extension Workspace {
    public mutating func undoTaskCompletion(_ action: TaskCompletionUndo, now: Date = Date()) throws {
        guard let current = record(action.completed.id), current == action.completed else {
            throw WorkspaceError("这项任务已被修改或删除，无法撤销先前的完成操作。")
        }
        guard current.kind == .task, current.status == .completed else { throw WorkspaceError("没有可撤销的任务完成操作。") }
        var restored = current
        restored.status = action.before.status; restored.completedAt = action.before.completedAt
        try putRecord(restored, now: now)
    }
}
extension WorkRecord {
    public func withDeadline(on day: Date) throws -> WorkRecord {
        guard kind == .task else { throw WorkspaceError("只有任务可以快捷调整截止日期。") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        var value = self
        if let dueAt, !dueDateOnly {
            let time = calendar.dateComponents([.hour, .minute, .second], from: dueAt)
            guard let date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: calendar.startOfDay(for: day)) else {
                throw WorkspaceError("无法计算该日期的截止时间。")
            }
            value.dueAt = date
        } else {
            value.dueAt = calendar.startOfDay(for: day); value.dueDateOnly = true
        }
        return value
    }
}
