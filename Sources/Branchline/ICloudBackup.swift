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
            guard let data = try savedPersonalBackupData() else { return }
            let changed = fingerprint(data) != lastPersonalICloudFingerprint
            if iCloudHasChanges != changed { iCloudHasChanges = changed }
            guard DailyBackupSchedule.shouldBackup(now: now, lastSuccess: lastPersonalICloudBackupAt, enabledSince: enabled, minuteOfDay: iCloudBackupMinutes, hasChanges: changed) else { return }
            try writeICloudBackup(data, demo: false, automatic: true, at: now)
        } catch {
            iCloudBackupFailed = true
            iCloudBackupMessage = "自动备份未完成：\(error.localizedDescription)；应用运行时将稍后重试。"
            nextICloudBackupAttempt = now.addingTimeInterval(3600)
        }
    }
    private var iCloudDrive: URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "BranchlineICloudBackupDirectory") as? String { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    var iCloudBackupDirectory: URL { iCloudDrive.appendingPathComponent("脉络备份", isDirectory: true) }
    var deviceName: String { Host.current().localizedName ?? "Mac" }
    func writeICloudBackup(_ data: Data, demo: Bool, automatic: Bool = false, at now: Date = Date()) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: iCloudDrive.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError("未找到 iCloud 云盘。请在系统设置中开启，并确认访达可以打开；也可使用“导出完整备份”自行选择位置。")
        }
        let directory = iCloudBackupDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let space = demo ? "示例空间" : "个人空间"
        let url = directory.appendingPathComponent(ICloudBackupFiles.fileName(space: space, stamp: fileDate(now), device: deviceName, automatic: automatic && !demo))
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
        iCloudHasChanges = demo ? iCloudHasChanges : false
        iCloudBackupMessage = ""
        if automatic && !demo { pruneICloudBackups() }
        refreshICloudBackups()
    }
    /// Deletes older automatic backups made on this Mac; manual backups are never touched.
    func pruneICloudBackups() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: iCloudBackupDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = urls.filter { $0.pathExtension == "json" }.map { (name: $0.lastPathComponent, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for name in ICloudBackupFiles.prunable(files, device: deviceName) { try? fm.removeItem(at: iCloudBackupDirectory.appendingPathComponent(name)) }
    }
    /// Lists the newest backups in the iCloud folder, from any Mac, with their upload state.
    func refreshICloudBackups(limit: Int = 6) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: iCloudBackupDirectory, includingPropertiesForKeys: keys) else { iCloudBackups = []; return }
        iCloudBackups = urls.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("脉络-") }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let upload: ICloudBackupEntry.Upload = values?.ubiquitousItemUploadingError != nil ? .failed : values?.ubiquitousItemIsUploaded == true ? .uploaded : values?.ubiquitousItemIsUploading == true ? .uploading : values?.ubiquitousItemIsUploaded == false ? .waiting : .unknown
            return ICloudBackupEntry(url: url, date: values?.contentModificationDate ?? .distantPast, personal: ICloudBackupFiles.isPersonal(url.lastPathComponent), automatic: ICloudBackupFiles.isAutomatic(url.lastPathComponent), device: ICloudBackupFiles.device(in: url.lastPathComponent), upload: upload)
        }.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }
    /// One line for the settings page: when the next automatic backup runs, or why it was skipped.
    var iCloudScheduleText: String? {
        guard iCloudAutoEnabled, let since = iCloudAutoEnabledSince else { return nil }
        switch DailyBackupSchedule.status(now: Date(), lastSuccess: lastPersonalICloudBackupAt, enabledSince: since, minuteOfDay: iCloudBackupMinutes, hasChanges: iCloudHasChanges) {
        case .scheduled(let date): return date.timeIntervalSinceNow < 60 ? "即将自动备份" : "下次自动备份：" + WorkDateText.short(date, timed: true)
        case .skippedNoChanges(let next): return "今天没有改动，已跳过 · 下次 " + WorkDateText.short(next, timed: true)
        }
    }
}

struct ICloudBackupEntry: Identifiable, Equatable {
    enum Upload: Equatable { case uploaded, uploading, waiting, failed, unknown
        var title: String { switch self { case .uploaded: "已上传"; case .uploading: "上传中"; case .waiting: "等待上传"; case .failed: "上传失败"; case .unknown: "" } }
    }
    var url: URL
    var date: Date
    var personal: Bool
    var automatic: Bool
    var device: String?
    var upload: Upload
    var id: URL { url }
}
