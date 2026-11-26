import ServiceManagement
import Observation

@MainActor @Observable final class LoginItemService {
    private(set) var status = SMAppService.mainApp.status
    private(set) var errorMessage: String?

    // Pending approval is still a registered request, so it must remain removable.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    var statusText: String {
        switch status {
        case .enabled: "已开启，下次登录此 Mac 时自动启动。"
        case .notRegistered: "已关闭。"
        case .requiresApproval: "等待系统批准，请在系统登录项设置中允许“脉络”。"
        case .notFound: "系统尚未找到登录项，可尝试开启以注册；若失败会显示原因。"
        @unknown default: "无法识别系统状态，请检查系统登录项设置。"
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != isRegistered else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "未能更改登录启动：\(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
