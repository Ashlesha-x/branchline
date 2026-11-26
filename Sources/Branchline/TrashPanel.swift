import SwiftUI
import ProgressCore

struct TrashPanel: View {
    @Bindable var store: AppStore
    @LocalState private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 20).padding(.bottom, 12) }
            if store.workspace.trash.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash", description: Text("删除的项目、分支、记录和会议例外会在这里保留 \(Workspace.retentionDays) 天。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("删除的内容保留 \(Workspace.retentionDays) 天后自动清除。永久删除后无法恢复；删除前的自动备份同样在 \(Workspace.retentionDays) 天后清除。")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.workspace.trash.reversed(), id: \.id.uuidString) { entry in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(alignment: .top) {
                                    Text(entry.title).fontWeight(.medium).lineLimit(3)
                                    Spacer()
                                    Button("恢复") {
                                        do { try store.commit { $0 = try $0.restoringTrash(entry.id) }; error = nil; store.notice = "已恢复「\(entry.title)」。" }
                                        catch { self.error = error.localizedDescription }
                                    }.accessibilityLabel("恢复\(entry.title)")
                                    Button("永久删除", role: .destructive) { purge(entry) }.accessibilityLabel("永久删除\(entry.title)")
                                }
                                Text(WorkDateText.date(entry.deletedAt, timed: true)).font(.caption).foregroundStyle(.secondary)
                                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20).scrollTargetLayout()
                }.rememberingBrowsePosition(store, surface: "trash")
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func purge(_ entry: TrashEntry) {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "永久删除「\(entry.title)」？"
        alert.informativeText = "\(entry.summary)\n\n永久删除后无法从回收站恢复。"
        alert.addButton(withTitle: "取消").keyEquivalent = "\r"
        alert.addButton(withTitle: "永久删除").hasDestructiveAction = true
        guard DialogPresentation.confirm(alert) == .alertSecondButtonReturn else { return }
        do {
            try store.commit { $0 = try $0.purgingTrash(entry.id) }
            if store.recentDeletionID == entry.id { store.recentDeletionID = nil }
            error = nil; store.notice = "已永久删除「\(entry.title)」。"
        } catch { self.error = error.localizedDescription }
    }
}
