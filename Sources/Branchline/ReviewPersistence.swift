import Foundation
import ProgressCore

extension AppStore {
    var reviewRepository: ReviewDraftRepository { ReviewDraftRepository(url: workspaceDirectory.appendingPathComponent("Drafts/review.json")) }
    func adoptReviewDraft(_ value: ReviewDraft?) {
        reviewSaveTask?.cancel(); reviewSaveTask = nil
        reviewLoading = true
        reviewDraft = value ?? .currentWeek()
        reviewLoading = false; reviewNeedsWrite = false
        reviewSaveStatus = value == nil ? "" : "回顾已暂存"
    }
    func loadReviewDraft() {
        reviewReadFailed = false
        if isDemo { adoptReviewDraft(nil); return }
        do { adoptReviewDraft(try reviewRepository.load()) }
        catch { adoptReviewDraft(nil); reviewReadFailed = true; reviewSaveStatus = "原回顾暂存无法读取，已保留；当前文字尚不能自动暂存。" }
    }
    func scheduleReviewSave() {
        guard !reviewLoading, !isDemo, !reviewReadFailed else { return }
        reviewNeedsWrite = true; reviewSaveStatus = "正在暂存…"; reviewSaveTask?.cancel()
        reviewSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushReviewDraft()
        }
    }
    func flushReviewDraft() {
        reviewSaveTask?.cancel(); reviewSaveTask = nil
        guard reviewNeedsWrite, !isDemo, !reviewReadFailed else { return }
        do { try reviewRepository.save(reviewDraft); reviewNeedsWrite = false; reviewSaveStatus = "回顾已暂存" }
        catch { reviewSaveStatus = "回顾暂存失败，请先复制或导出当前文字。" }
    }
}
