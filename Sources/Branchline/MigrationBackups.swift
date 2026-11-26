import Foundation
import ProgressCore

extension AppStore {
    var migrationJournal: MigrationRestoreJournal { MigrationRestoreJournal(url: dataDirectory.appendingPathComponent("Drafts/restore-journal.json")) }
    func migrationSnapshot(personal: Bool = false) throws -> MigrationBackup {
        guard !reviewReadFailed || (personal && isDemo) else { throw WorkspaceError("回顾暂存文件无法读取，未创建缺少回顾的备份。") }
        let values: [RecordDraft]
        if personal && isDemo { values = try draftRepository.load() }
        else {
            guard !draftReadFailed else { throw WorkspaceError("原草稿文件无法读取，未创建缺少草稿的备份。") }
            values = recordDrafts
        }
        return MigrationBackup(workspace: personal ? try personalWorkspaceSnapshot() : workspace, drafts: values, review: personal && isDemo ? try reviewRepository.load() : reviewDraft)
    }
    func recoverInterruptedMigration(using repository: WorkspaceRepository) throws {
        try migrationJournal.recover(saveWorkspace: { try repository.save($0) }, saveDrafts: { try draftRepository.save($0) }, saveReview: { try reviewRepository.save($0) })
    }
}
