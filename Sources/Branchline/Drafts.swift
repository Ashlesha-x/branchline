import SwiftUI
import ProgressCore

extension RecurringEdit {
    var draftValue: DraftRecurrence { DraftRecurrence(seriesID: seriesID, occurrence: occurrence, scope: scope) }
    init?(_ value: DraftRecurrence?) {
        guard let value, let scope = RecurrenceScope(rawValue: value.scope) else { return nil }
        self.init(seriesID: value.seriesID, occurrence: value.occurrence, scope: scope)
    }
}

extension AppStore {
    var draftRepository: RecordDraftRepository { RecordDraftRepository(url: dataDirectory.appendingPathComponent("Drafts/records.json")) }
    func loadDrafts() {
        draftRecoveryCollapsed = false
        loadReviewDraft()
        draftWriteTask?.cancel()
        draftSavedAt = nil; draftError = nil; draftReadFailed = false; draftNeedsWrite = false
        if isDemo { recordDrafts = []; return }
        do { let loaded = try draftRepository.load(); recordDrafts = loaded.filter { !$0.alreadySaved(in: workspace) }; draftSavedAt = loaded.map(\.updatedAt).max(); draftNeedsWrite = loaded.count != recordDrafts.count }
        catch { recordDrafts = []; draftReadFailed = true; draftError = "原草稿文件无法读取，已保留。" }
    }
    func checkpointDraft(_ record: WorkRecord, original: WorkRecord?, recurrence: RecurringEdit? = nil, dirty: Bool, key: String? = nil, taskScope: RecurrenceScope? = nil) {
        let value = RecordDraft(record: record, original: original, recurrence: recurrence?.draftValue, sourceKey: key, taskScope: taskScope)
        guard !value.alreadySaved(in: workspace) else { removeDraft(value.id); return }
        guard dirty else { if recordDrafts.contains(where: { $0.id == value.id }) { removeDraft(value.id) }; return }
        if let existing = recordDrafts.first(where: { $0.id == value.id }), existing.record == record, existing.original == original, existing.taskScope == taskScope { return }
        recordDrafts.removeAll { $0.id == value.id }; recordDrafts.insert(value, at: 0)
        draftSavedAt = nil; draftNeedsWrite = true
        draftWriteTask?.cancel()
        draftWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flushDrafts()
        }
    }
    func flushDrafts() {
        draftWriteTask?.cancel()
        guard draftNeedsWrite, !isDemo, !draftReadFailed else { return }
        do { try draftRepository.save(recordDrafts); draftSavedAt = Date(); draftError = nil; draftNeedsWrite = false }
        catch { draftError = "草稿尚未写入磁盘，请保留编辑窗口。" }
    }
    func removeDraft(_ id: String) {
        guard recordDrafts.contains(where: { $0.id == id }) else { return }
        recordDrafts.removeAll { $0.id == id }; draftNeedsWrite = true; flushDrafts()
    }
    var recoverableDrafts: [RecordDraft] {
        recordDrafts.filter { !($0.id == quickRecord?.id.uuidString && quickIsDirty) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func resumeDraft(_ value: RecordDraft) { editor = .restoredDraft(value) }
    func draftStatus(_ id: String) -> String? {
        guard !isDemo, recordDrafts.contains(where: { $0.id == id }) else { return nil }
        return draftError ?? (draftSavedAt == nil ? "正在保存草稿…" : "草稿已保存")
    }
    func matchingDraft(for route: EditorRoute) -> RecordDraft? {
        let key: String
        switch route {
        case .record(let r): key = RecordDraft.key(r.id)
        case .recurring(let r, let edit): key = RecordDraft.key(r.id, recurrence: edit.draftValue)
        default: return nil
        }
        return recordDrafts.first { $0.id == key }
    }
}

struct DraftRecoveryBar: View {
    var store: AppStore
    var body: some View {
        if let draft = store.recoverableDrafts.first, !store.draftRecoveryCollapsed {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text("未完成：" + (draft.record.title.isEmpty ? draft.record.kind.title : draft.record.title)).lineLimit(1)
                Spacer()
                Button("继续编辑") { store.resumeDraft(draft) }
                if store.recoverableDrafts.count > 1 {
                    Menu("其他草稿 \(store.recoverableDrafts.count - 1)") {
                        ForEach(store.recoverableDrafts.dropFirst()) { value in
                            Button(value.record.title.isEmpty ? value.record.kind.title : value.record.title) { store.resumeDraft(value) }
                        }
                    }
                }
                Button { store.draftRecoveryCollapsed = true } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }.buttonStyle(.plain).help("收起提示，草稿保留在工具栏").accessibilityLabel("收起草稿提示")
            }.font(.callout).padding(.horizontal, 18).padding(.vertical, 9).background(Color.primary.opacity(0.025))
        } else if let error = store.draftError {
            Text(error).font(.caption).foregroundStyle(.red).padding(10)
        }
    }
}
