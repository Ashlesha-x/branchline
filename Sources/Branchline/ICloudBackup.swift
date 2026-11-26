import SwiftUI
import CryptoKit
import ProgressCore

extension AppStore {
    func iCloudBackupTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(Locale(identifier: "zh_CN")))
    }
    private var cloudPreferenceKey: String { "iCloudBackup." + dataDirectory.path }
    private func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func startICloudBackupMonitor() {
        let defaults = UserDefaults.standard
        iCloudAutoEnabled = defaults.bool(forKey: cloudPreferenceKey + ".enabled")
        if defaults.object(forKey: cloudPreferenceKey + ".minutes") != nil { iCloudBackupMinutes = min(1439, max(0, defaults.integer(forKey: cloudPreferenceKey + ".minutes"))) }
        func date(_ field: String) -> Date? { let time = defaults.double(forKey: cloudPreferenceKey + field); return time > 0 ? Date(timeIntervalSince1970: time) : nil }
        iCloudAutoEnabledSince = date(".enabledSince")
        lastICloudBackupAt = date(".lastSuccess")
        lastPersonalICloudBackupAt = date(".lastPersonalSuccess")
        lastICloudBackupSpace = defaults.string(forKey: cloudPreferenceKey + ".space") ?? ""
        lastPersonalICloudFingerprint = defaults.string(forKey: cloudPreferenceKey + ".fingerprint")
        lastICloudBackupURL = defaults.string(forKey: cloudPreferenceKey + ".url").map { URL(fileURLWithPath: $0) }
        checkAutomaticICloudBackup()
        iCloudBackupMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.refreshRecurringTasks()
                self?.checkAutomaticICloudBackup()
            }
        }
    }
    func setAutomaticICloudBackup(_ enabled: Bool) {
        iCloudAutoEnabled = enabled
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: cloudPreferenceKey + ".enabled")
        if enabled {
            iCloudAutoEnabledSince = Date()
            defaults.set(iCloudAutoEnabledSince!.timeIntervalSince1970, forKey: cloudPreferenceKey + ".enabledSince")
            nextICloudBackupAttempt = .distantPast
            checkAutomaticICloudBackup()
        }
    }
    var iCloudBackupTime: Date {
        get { Calendar.current.date(bySettingHour: iCloudBackupMinutes / 60, minute: iCloudBackupMinutes % 60, second: 0, of: Date()) ?? Date() }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            iCloudBackupMinutes = (components.hour ?? 20) * 60 + (components.minute ?? 0)
            UserDefaults.standard.set(iCloudBackupMinutes, forKey: cloudPreferenceKey + ".minutes")
            nextICloudBackupAttempt = .distantPast
            checkAutomaticICloudBackup()
        }
    }
    func checkAutomaticICloudBackup(now: Date = Date()) {
        guard iCloudAutoEnabled, startupError == nil, now >= nextICloudBackupAttempt, let enabled = iCloudAutoEnabledSince else { return }
        do {
            guard let data = try savedPersonalBackupData(), DailyBackupSchedule.shouldBackup(now: now, lastSuccess: lastPersonalICloudBackupAt, enabledSince: enabled, minuteOfDay: iCloudBackupMinutes, hasChanges: fingerprint(data) != lastPersonalICloudFingerprint) else { return }
            try writeICloudBackup(data, demo: false, at: now)
        } catch {
            iCloudBackupFailed = true
            iCloudBackupMessage = "自动备份未完成：\(error.localizedDescription)；应用运行时将稍后重试。"
            nextICloudBackupAttempt = now.addingTimeInterval(3600)
        }
    }
    func writeICloudBackup(_ data: Data, demo: Bool, at now: Date = Date()) throws {
        let drive: URL
        if let path = Bundle.main.object(forInfoDictionaryKey: "BranchlineICloudBackupDirectory") as? String { drive = URL(fileURLWithPath: path, isDirectory: true) }
        else { drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError("未找到 iCloud 云盘。请在系统设置中开启，并确认访达可以打开；也可使用“导出完整备份”自行选择位置。")
        }
        let directory = drive.appendingPathComponent("脉络备份", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let space = demo ? "示例空间" : "个人空间"
        let url = directory.appendingPathComponent("脉络-\(space)-\(fileDate(now))-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        // Only a successful file write advances the schedule and displayed time.
        lastICloudBackupURL = url; lastICloudBackupAt = now; lastICloudBackupSpace = space
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: cloudPreferenceKey + ".url")
        defaults.set(now.timeIntervalSince1970, forKey: cloudPreferenceKey + ".lastSuccess")
        defaults.set(space, forKey: cloudPreferenceKey + ".space")
        if !demo {
            lastPersonalICloudBackupAt = now; lastPersonalICloudFingerprint = fingerprint(data)
            defaults.set(now.timeIntervalSince1970, forKey: cloudPreferenceKey + ".lastPersonalSuccess")
            defaults.set(lastPersonalICloudFingerprint, forKey: cloudPreferenceKey + ".fingerprint")
        }
        nextICloudBackupAttempt = .distantPast
        iCloudBackupFailed = false
        iCloudBackupMessage = "\(space)备份已写入 iCloud 云盘／脉络备份。上传状态请在访达中查看。"
    }
}
