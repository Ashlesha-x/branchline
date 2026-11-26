import SwiftUI
import AppKit
import ProgressCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, reminders, calendar, backup, ai, updates
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "通用"; case .reminders: "提醒"; case .calendar: "日历"; case .backup: "备份与恢复"; case .ai: "AI 接入"; case .updates: "关于与更新" }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .reminders: "bell"; case .calendar: "calendar"; case .backup: "externaldrive"; case .ai: "sparkles"; case .updates: "arrow.triangle.2.circlepath" }
    }
}

/// Settings inside the main window: a column of sections on the left, the selected section on the right.
struct SettingsPage: View {
    @Bindable var store: AppStore
    @AppStorage("settingsTab") private var tab = SettingsTab.general.rawValue
    private var current: SettingsTab { SettingsTab(rawValue: tab) ?? .general }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    Button { tab = item.rawValue } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(current == item ? Color.accentColor : .secondary)
                            Text(item.title)
                            Spacer(minLength: 0)
                            if item == .updates && AppUpdater.shared.hasUpdate { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                            if item == .calendar && store.calendarService.pendingChanges > 0 && !store.isDemo { Text("\(store.calendarService.pendingChanges)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(current == item ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(10).frame(width: 180)
            Divider()
            Group {
                switch current {
                case .general: GeneralSettings(store: store)
                case .reminders: ReminderSettings(store: store)
                case .calendar: CalendarSettings(store: store)
                case .backup: BackupSettings(store: store)
                case .ai: Form { AIClientSettings(store: store) }.formStyle(.grouped)
                case .updates: Form { UpdateSettingsSection(updater: AppUpdater.shared) }.formStyle(.grouped)
                }
            }
            .frame(maxWidth: 680, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var store: AppStore
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showDemoSpace") private var showDemoSpace = true
    var body: some View {
        Form {
            Section {
                Picker("外观", selection: $appearance) { Text("浅色").tag("light"); Text("深色").tag("dark"); Text("跟随系统").tag("system") }
                Toggle("登录时自动启动", isOn: Binding(get: { store.loginItem.isRegistered }, set: { store.loginItem.setEnabled($0) }))
                if let error = store.loginItem.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if store.loginItem.status == .requiresApproval || store.loginItem.errorMessage != nil {
                    LabeledContent(store.loginItem.statusText) { Button("打开登录项设置") { store.loginItem.openSystemSettings() } }
                }
            }
            Section {
                Toggle("显示示例空间", isOn: Binding(get: { showDemoSpace }, set: { on in
                    showDemoSpace = on
                    if !on && store.isDemo { do { try store.switchSpace(demo: false) } catch { store.error = error.localizedDescription } }
                })).help("关闭后，空间菜单和欢迎页不再提供示例空间。")
                LabeledContent("新手引导") {
                    Button("重新播放") {
                        if showDemoSpace && !store.isDemo { do { try store.switchSpace(demo: true) } catch { store.error = error.localizedDescription; return } }
                        if store.tourStop == nil { store.startTour() }
                    }.help(showDemoSpace ? "在示例空间里一步步介绍主要功能" : "一步步介绍主要功能")
                }
            }
            Section {
                ForEach(store.workspaceRegistry.entries) { entry in
                    let active = entry.id == store.activeWorkspaceID
                    HStack {
                        Image(systemName: "internaldrive").foregroundStyle(.secondary)
                        Text(entry.name)
                        if active { Text(store.isDemo ? "上次使用" : "正在使用").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if !active || store.isDemo { Button("打开") { do { try store.switchSpace(demo: false, workspaceID: entry.id) } catch { store.error = error.localizedDescription } } }
                        Button("重命名…") { store.promptRenameWorkspace(entry.id) }
                        Button("删除…") { store.confirmDeleteWorkspace(entry.id) }
                            .disabled(active || store.workspaceRegistry.entries.count == 1)
                            .help(active ? "正在使用的工作区不能删除，请先切换到其他工作区。" : store.workspaceRegistry.entries.count == 1 ? "至少要保留一个工作区。" : "删除前会再次确认，并要求输入名称。")
                    }
                }
                HStack { Spacer(); Button("新建工作区…") { store.promptNewWorkspace() } }
            } header: { Text("工作区") } footer: {
                Text("每个工作区的项目、草稿和回顾互不相通。提醒来自所有工作区；AI 接入和日历写回只作用于正在使用的工作区。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("数据文件夹") { Button("在访达中显示") { NSWorkspace.shared.open(store.dataDirectory) }.help(store.dataDirectory.path) }
            }
        }.formStyle(.grouped)
        .onAppear { store.loginItem.refresh() }
    }
}

private struct ReminderSettings: View {
    @Bindable var store: AppStore
    var body: some View {
        Form {
            Section {
                LabeledContent("系统通知", value: store.isDemo ? "示例空间不发送" : store.notifications.status)
                if !store.isDemo, let date = store.notifications.coverageUntil {
                    LabeledContent("已安排到", value: WorkDateText.short(date, timed: true))
                }
                HStack {
                    Spacer()
                    Button(store.notifications.needsSystemSettings ? "打开系统通知设置" : "启用通知") { store.notifications.enableOrOpenSettings(workspace: store.reminderWorkspace) }
                        .help(store.notifications.needsSystemSettings ? "打开“系统设置 › 通知”里脉络的设置页" : "请求系统通知权限；如已被拒绝，会打开系统设置")
                    Button("发送测试通知") { store.notifications.sendTest() }.help("5 秒后发送测试通知")
                }.disabled(store.isDemo)
            } footer: {
                if !store.isDemo && store.notifications.hasUnscheduledReminders { Text("还有提醒等待排入，脉络运行时会自动续排。").font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
    }
}

private struct CalendarSettings: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("calendar.writeNewMeetings") private var writeNewMeetings = false
    private var service: AppleCalendarService { store.calendarService }
    var body: some View {
        Form {
            Section {
                LabeledContent("访问权限") {
                    if service.connected { Label("已允许", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button(service.denied ? "打开系统设置" : "允许访问") { Task { await service.connect() } }.disabled(service.connecting) }
                }
                if !service.message.isEmpty { Text(service.message).font(.caption).foregroundStyle(.secondary) }
            }
            if service.connected {
                Section("读取") {
                    LabeledContent("来源日历", value: service.selectedCalendars.isEmpty ? "未选择" : service.selectedCalendars.map(\.title).joined(separator: "、"))
                    Stepper("向后读取 \(service.rangeDays) 天", value: Binding(get: { service.rangeDays }, set: { service.rangeDays = $0 }), in: 1...366, step: 7)
                    LabeledContent(service.lastSyncSummary ?? "尚未同步") {
                        Button(service.pendingChanges > 0 ? "处理 \(service.pendingChanges) 处变化…" : "打开日历同步…") { openWindow(id: "calendar-sync"); NSApp.activate(ignoringOtherApps: true) }
                    }
                }
                Section {
                    Picker("写入的日历", selection: Binding(get: { service.writeTarget?.id }, set: { service.defaultWriteCalendarID = $0 })) {
                        Text("不写入").tag(String?.none)
                        ForEach(service.writableCalendars) { calendar in Text("\(calendar.title) · \(calendar.source)").tag(Optional(calendar.id)) }
                    }
                    Toggle("新会议默认勾选「同步到电脑日历」", isOn: $writeNewMeetings).disabled(service.writeTarget == nil)
                } header: { Text("写回") } footer: {
                    Text("已关联的会议在脉络里修改后会自动写回；日历里也改过时，不覆盖，留到日历同步里处理。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
        .onAppear { service.loadIfAuthorized(); service.refreshPending(workspace: store.workspace, demo: store.isDemo) }
    }
}

private struct BackupSettings: View {
    @Bindable var store: AppStore
    var body: some View {
        Form {
            Section("iCloud 云盘") {
                Toggle("每日自动备份", isOn: Binding(get: { store.iCloudAutoEnabled }, set: { store.setAutomaticICloudBackup($0) }))
                if store.iCloudAutoEnabled {
                    DatePicker("备份时间", selection: Binding(get: { store.iCloudBackupTime }, set: { store.iCloudBackupTime = $0 }), displayedComponents: [.hourAndMinute])
                }
                LabeledContent("状态") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(store.lastPersonalICloudBackupAt.map { "上次备份 " + WorkDateText.short($0, timed: true) } ?? "还没有备份")
                        if let schedule = store.iCloudScheduleText { Text(schedule).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !store.iCloudBackupMessage.isEmpty {
                    Text(store.iCloudBackupMessage).font(.caption).foregroundStyle(store.iCloudBackupFailed ? Color.red : Color.secondary).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.open(store.iCloudBackupDirectory) }
                        .disabled(!FileManager.default.fileExists(atPath: store.iCloudBackupDirectory.path))
                    Button("立即备份") { store.exportICloudBackup() }
                        .disabled(store.isDemo).help(store.isDemo ? "示例空间不备份" : "把当前工作区备份到 iCloud 云盘／脉络备份")
                }
            }
            if !store.iCloudBackups.isEmpty {
                Section("最近的 iCloud 备份") {
                    ForEach(store.iCloudBackups) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(WorkDateText.short(entry.date, timed: true))
                                Text([entry.space, entry.device, entry.automatic ? "自动" : "手动", entry.upload.title.isEmpty ? nil : entry.upload.title].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(entry.upload == .failed ? Color.red : Color.secondary)
                            }
                            Spacer()
                            Button("恢复…") { store.restoreBackup(at: entry.url) }.controlSize(.small).disabled(store.fileDialogPending)
                        }
                    }
                }
            }
            Section("本机") {
                LabeledContent("完整备份") {
                    HStack { Button("导出…") { store.exportBackup() }; Button("从文件恢复…") { store.importBackup() } }
                }
                LabeledContent("自动备份（删除、恢复前）") { Button("在访达中显示") { store.openBackupFolder() } }
            }
        }.formStyle(.grouped)
        .onAppear { store.refreshICloudBackups() }
    }
}
