import AppKit
import ProgressCore

/// User workspaces. The first ("default") workspace keeps its files directly in the data
/// directory, as before; others live in Workspaces/<id>/ with their own store, drafts and backups.
extension AppStore {
    private var registryURL: URL { dataDirectory.appendingPathComponent("workspaces.json") }
    private var activeWorkspaceKey: String { "activeWorkspace." + dataDirectory.path }

    func workspaceDirectory(for id: String) -> URL {
        id == WorkspaceEntry.defaultID ? dataDirectory : dataDirectory.appendingPathComponent("Workspaces", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    var workspaceDirectory: URL { workspaceDirectory(for: activeWorkspaceID) }
    var activeWorkspaceName: String { workspaceRegistry.entry(activeWorkspaceID)?.name ?? "个人空间" }
    var spaceTitle: String { isDemo ? "示例空间" : activeWorkspaceName }

    func loadWorkspaceRegistry() {
        if let data = try? Data(contentsOf: registryURL), let value = try? JSONDecoder.workspaceRegistry.decode(WorkspaceRegistry.self, from: data), !value.entries.isEmpty {
            workspaceRegistry = value
        }
        let stored = UserDefaults.standard.string(forKey: activeWorkspaceKey) ?? WorkspaceEntry.defaultID
        activeWorkspaceID = workspaceRegistry.entry(stored) == nil ? workspaceRegistry.entries[0].id : stored
    }
    private func saveWorkspaceRegistry(_ value: WorkspaceRegistry) throws {
        try JSONEncoder.workspaceRegistry.encode(value).write(to: registryURL, options: .atomic)
        workspaceRegistry = value
    }

    /// Records of the workspaces that are not open, so their reminders still fire.
    func loadOtherWorkspaceRecords() {
        var result: [String: [WorkRecord]] = [:]
        for entry in workspaceRegistry.entries where entry.id != activeWorkspaceID {
            let store = workspaceDirectory(for: entry.id).appendingPathComponent("personal.store")
            guard FileManager.default.fileExists(atPath: store.path) else { continue }
            result[entry.id] = (try? WorkspaceRepository(url: store).load())?.records ?? []
        }
        otherWorkspaceRecords = result
    }
    /// The open workspace plus the records of every other workspace; reminders come from all of them.
    var reminderWorkspace: Workspace {
        var merged = workspace
        for records in otherWorkspaceRecords.values { merged.records += records }
        return merged
    }
    func refreshReminders() {
        guard !isDemo else { return }
        notifications.refresh(workspace: reminderWorkspace, demo: false)
    }
    /// Opens the record a notification points to, switching to the workspace that holds it.
    func openReminderFromNotification(_ target: ReminderNotificationTarget) {
        let owner = otherWorkspaceRecords.first { $0.value.contains { $0.id == target.recordID } }?.key
        do {
            if let owner { try switchSpace(demo: false, workspaceID: owner) }
            else if isDemo { try switchSpace(demo: false) }
        } catch { self.error = error.localizedDescription; return }
        if !isDemo { openReminder(target) }
    }

    func createWorkspace(named name: String) {
        do {
            var next = workspaceRegistry
            let entry = try next.add(name: name)
            try FileManager.default.createDirectory(at: workspaceDirectory(for: entry.id), withIntermediateDirectories: true)
            try saveWorkspaceRegistry(next)
            try switchSpace(demo: false, workspaceID: entry.id)
        } catch { self.error = error.localizedDescription }
    }
    func renameWorkspace(_ id: String, to name: String) {
        do {
            var next = workspaceRegistry
            try next.rename(id, to: name)
            try saveWorkspaceRegistry(next)
        } catch { self.error = error.localizedDescription }
    }
    /// Moves the workspace's files to "已删除的工作区" in the data folder, with a full backup beside them.
    func deleteWorkspace(_ id: String, confirmation: String) throws {
        var next = workspaceRegistry
        let entry = try next.remove(id, active: activeWorkspaceID, confirmation: confirmation)
        let fm = FileManager.default
        let source = workspaceDirectory(for: id)
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)) + "-" + String(UUID().uuidString.prefix(4))
        let target = dataDirectory.appendingPathComponent("已删除的工作区", isDirectory: true).appendingPathComponent(ICloudBackupFiles.sanitize(entry.name) + "-" + stamp, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try backupData(forWorkspace: id).write(to: target.appendingPathComponent("完整备份.json"), options: .atomic)
        if id == WorkspaceEntry.defaultID {
            // The first workspace shares the data folder with app-wide files; move only its own.
            let names = ["personal.store", "personal.store-shm", "personal.store-wal", "Drafts", "Backups"]
            for name in names where fm.fileExists(atPath: source.appendingPathComponent(name).path) {
                try fm.moveItem(at: source.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
        } else if fm.fileExists(atPath: source.path) {
            try fm.moveItem(at: source, to: target.appendingPathComponent("文件", isDirectory: true))
        }
        try saveWorkspaceRegistry(next)
        otherWorkspaceRecords[id] = nil; otherWorkspaceBackups[id] = nil
        refreshReminders()
        notice = "已删除工作区「\(entry.name)」。文件已移到数据文件夹的“已删除的工作区”中。"
    }

    /// A full backup (content, drafts and review) of any workspace, open or not.
    func backupData(forWorkspace id: String) throws -> Data {
        if id == activeWorkspaceID { return try migrationSnapshot(personal: true).encoded() }
        if let cached = otherWorkspaceBackups[id] { return cached }
        let directory = workspaceDirectory(for: id)
        let store = directory.appendingPathComponent("personal.store")
        let value = FileManager.default.fileExists(atPath: store.path) ? try WorkspaceRepository(url: store).load() ?? Workspace() : Workspace()
        let drafts = try RecordDraftRepository(url: directory.appendingPathComponent("Drafts/records.json")).load()
        let review = try ReviewDraftRepository(url: directory.appendingPathComponent("Drafts/review.json")).load()
        let data = try MigrationBackup(workspace: value, drafts: drafts, review: review).encoded()
        otherWorkspaceBackups[id] = data
        return data
    }

    func rememberActiveWorkspace() { UserDefaults.standard.set(activeWorkspaceID, forKey: activeWorkspaceKey) }

    /// A small text prompt for a workspace name; nil when cancelled.
    func askWorkspaceName(title: String, message: String = "", initial: String = "", confirm: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = initial; field.placeholderString = "工作区名称"
        alert.accessoryView = field
        alert.addButton(withTitle: confirm); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard DialogPresentation.confirm(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
    func promptNewWorkspace() {
        guard let name = askWorkspaceName(title: "新建工作区", message: "新的工作区有自己独立的项目、草稿和回顾。", confirm: "新建") else { return }
        createWorkspace(named: name)
    }
    /// Two steps: a warning, then the workspace's name typed back.
    func confirmDeleteWorkspace(_ id: String) {
        guard let entry = workspaceRegistry.entry(id) else { return }
        let warning = NSAlert(); warning.alertStyle = .critical
        warning.messageText = "删除工作区「\(entry.name)」？"
        warning.informativeText = "其中的 \(otherWorkspaceRecords[id]?.count ?? 0) 条记录以及项目、分支、草稿和回顾都会从脉络中移除。文件会移到数据文件夹的“已删除的工作区”里，并附一份完整备份，需要时可以从备份恢复。"
        warning.addButton(withTitle: "继续"); warning.addButton(withTitle: "取消")
        guard DialogPresentation.confirm(warning) == .alertFirstButtonReturn else { return }
        guard let typed = askWorkspaceName(title: "请输入「\(entry.name)」确认删除", message: "名称一致才会删除。", confirm: "删除") else { return }
        do { try deleteWorkspace(id, confirmation: typed) } catch { self.error = error.localizedDescription }
    }
    func promptRenameWorkspace(_ id: String) {
        guard let entry = workspaceRegistry.entry(id), let name = askWorkspaceName(title: "重命名工作区", initial: entry.name, confirm: "重命名") else { return }
        renameWorkspace(id, to: name)
    }
}

extension JSONEncoder {
    static var workspaceRegistry: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
extension JSONDecoder {
    static var workspaceRegistry: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
