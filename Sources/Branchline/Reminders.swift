import AppKit
import Combine
import Observation
import UserNotifications
import ProgressCore

@MainActor @Observable final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    var status = "未请求通知权限"
    var scheduledCount = 0
    var coverageUntil: Date?
    var hasUnscheduledReminders = false
    private var generation = 0
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: AnyCancellable?
    @ObservationIgnored private var latestWorkspace: Workspace?
    @ObservationIgnored private var openHandler: ((ReminderNotificationTarget) -> Void)?
    @ObservationIgnored private var pendingTarget: ReminderNotificationTarget?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refill() } }
    }
    func installOpenHandler(_ handler: @escaping (ReminderNotificationTarget) -> Void) {
        openHandler = handler
        if let target = pendingTarget { pendingTarget = nil; handler(target) }
    }
    func sendTest() {
        Task {
            do {
                let center = UNUserNotificationCenter.current()
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { status = "系统通知未开启；请在系统设置中允许脉络通知。"; return }
                let content = UNMutableNotificationContent(); content.title = "脉络 · 提醒测试"; content.body = "本地提醒已送达。你可以为任务和会议设置提醒。"; content.sound = .default
                try await center.add(UNNotificationRequest(identifier: "branchline-test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
                status = "测试通知已安排，将在约 5 秒后发送。"
            } catch {
                if (error as? UNError)?.code == .notificationsNotAllowed { status = "系统不允许此应用发送通知；请在系统设置中检查通知权限。" }
                else { status = "测试通知失败：\(error.localizedDescription)" }
            }
        }
    }
    func requestAndRefresh(workspace: Workspace) {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                if granted { refresh(workspace: latestWorkspace ?? workspace, demo: false) }
                else { status = "系统通知未开启；到期事项仍在应用中显示" }
            } catch { status = "通知不可用：\(error.localizedDescription)" }
        }
    }
    func refresh(workspace: Workspace, demo: Bool) {
        guard !demo else { return }
        latestWorkspace = workspace
        refillTask?.cancel()
        generation += 1; let token = generation
        let previous = queueTask
        queueTask = Task { [weak self] in
            await previous?.value
            await self?.reconcile(workspace, token: token)
        }
    }
    private func refill() {
        if let latestWorkspace { refresh(workspace: latestWorkspace, demo: false) }
    }
    private func planRefill(after seconds: TimeInterval) {
        refillTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.refill()
        }
    }
    private func reconcile(_ workspace: Workspace, token: Int) async {
        guard token == generation else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        guard token == generation else { return }
        let existing = Dictionary(uniqueKeysWithValues: pending.filter { $0.identifier.hasPrefix("branchline.") }.map { ($0.identifier, $0) })
        let validIDs = Set(workspace.records.map { $0.id.uuidString })
        center.removeDeliveredNotifications(withIdentifiers: delivered.compactMap { notification in
            guard notification.request.identifier.hasPrefix("branchline."),
                  let id = notification.request.content.userInfo["recordID"] as? String, !validIDs.contains(id) else { return nil }
            return notification.request.identifier
        })
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            center.removePendingNotificationRequests(withIdentifiers: Array(existing.keys))
            scheduledCount = 0
            coverageUntil = nil
            hasUnscheduledReminders = false
            status = settings.authorizationStatus == .denied ? "系统通知未开启" : "尚未启用系统通知"
            return
        }
        let queue = workspace.reminderQueue(now: Date(), capacity: 64 - (pending.count - existing.count))
        let desired = Set(queue.scheduled.map(\.id))
        let obsolete = existing.keys.filter { !desired.contains($0) }
        if !obsolete.isEmpty { center.removePendingNotificationRequests(withIdentifiers: obsolete) }

        var scheduled: [Date] = []
        var failure: String?
        for item in queue.scheduled {
            guard token == generation else { return }
            guard item.fireDate > Date() else { continue }
            let record = item.record
            let body = "\(record.kind.title) · \(record.body.isEmpty ? "打开脉络查看详情" : String(record.body.prefix(100)))"
            if let content = existing[item.id]?.content, content.title == record.title, content.body == body {
                scheduled.append(item.fireDate)
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = record.title; content.body = body; content.sound = .default
            content.userInfo = item.target.userInfo
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.fireDate)
            parts.calendar = calendar; parts.timeZone = calendar.timeZone
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            do { try await center.add(request); scheduled.append(item.fireDate) }
            catch { failure = error.localizedDescription }
        }
        guard token == generation else { return }
        let now = Date()
        let future = scheduled.filter { $0 > now }
        scheduledCount = future.count
        coverageUntil = future.last
        hasUnscheduledReminders = queue.hasMore
        status = failure.map { "部分提醒尚未安排：\($0)" } ?? "已安排 \(future.count) 条系统提醒"
        let delayUntilNextSlot = scheduled.first.map { max(1, $0.timeIntervalSince(now) + 1) } ?? 60
        planRefill(after: failure != nil ? 60 : queue.hasMore ? min(3600, delayUntilNextSlot) : 3600)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.identifier == "branchline-test" { await MainActor.run { status = "已收到系统发送的测试通知。" } }
        return [.banner, .sound, .list]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let target = ReminderNotificationTarget(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            if let openHandler { openHandler(target) }
            else { pendingTarget = target }
        }
    }
}
