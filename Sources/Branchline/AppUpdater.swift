import AppKit
import SwiftUI
import CryptoKit
import Observation
import ProgressCore

/// Checks GitHub Releases, downloads the new package, and replaces the app bundle in place.
/// The swap happens in a small shell helper after this process exits, then the new version is opened.
@MainActor @Observable final class AppUpdater {
    static let shared = AppUpdater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo, ReleaseAsset)
        case manualOnly(ReleaseInfo)
        case downloading(ReleaseInfo)
        case ready(ReleaseInfo, URL)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastCheckAt: Date? = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date
    var autoUpdate: Bool = UserDefaults.standard.object(forKey: Keys.auto) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoUpdate, forKey: Keys.auto)
            if autoUpdate { checkIfDue() }
        }
    }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var schedule: Task<Void, Never>?
    private enum Keys { static let auto = "autoUpdateEnabled"; static let lastCheck = "lastUpdateCheckAt" }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    private var bundleURL: URL { Bundle.main.bundleURL }
    private var isAppBundle: Bool { bundleURL.pathExtension == "app" }

    var installBlocker: String? {
        guard isAppBundle else { return "当前是开发构建，不在 .app 中运行，无法自动替换。" }
        let parent = bundleURL.deletingLastPathComponent().path
        return AppUpdatePolicy.installBlocker(bundlePath: bundleURL.path, parentWritable: FileManager.default.isWritableFile(atPath: parent))
    }

    var hasUpdate: Bool {
        switch phase { case .available, .manualOnly, .downloading, .ready: true; default: false }
    }

    var busy: Bool {
        switch phase { case .checking, .downloading, .installing: true; default: false }
    }

    var statusText: String {
        switch phase {
        case .idle: lastCheckAt.map { "上次检查：\(WorkDateText.date($0, timed: true))" } ?? "尚未检查更新。"
        case .checking: "正在检查更新…"
        case .upToDate: "已是最新版本。" + (lastCheckAt.map { "（\(WorkDateText.date($0, timed: true)) 检查）" } ?? "")
        case .available(let release, _): "发现新版本 \(release.displayVersion)。"
        case .manualOnly(let release): "发现新版本 \(release.displayVersion)，但没有可自动安装的安装包，请到下载页面手动更新。"
        case .downloading(let release): "正在下载 \(release.displayVersion)…"
        case .ready(let release, _): "\(release.displayVersion) 已下载，重启脉络即可完成更新" + (autoUpdate ? "；退出脉络时也会自动安装。" : "。")
        case .installing: "正在安装更新，脉络将自动重新打开…"
        case .failed(let message): message
        }
    }

    /// Called once at launch: checks shortly after start, then hourly whether a daily check is due.
    func start() {
        guard !started else { return }
        started = true
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func checkIfDue() {
        guard autoUpdate, !busy, AppUpdatePolicy.isDue(lastCheck: lastCheckAt, now: Date()) else { return }
        if case .ready = phase { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        if case .ready = phase, !userInitiated { return }
        let previous = phase
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            lastCheckAt = Date(); UserDefaults.standard.set(lastCheckAt, forKey: Keys.lastCheck)
            switch AppUpdatePolicy.decide(current: currentVersion, release: release) {
            case .upToDate: phase = .upToDate
            case .manualOnly(let release): phase = .manualOnly(release)
            case .available(let release, let asset):
                if case .ready(let staged, _) = previous, staged.tagName == release.tagName { phase = previous; return }
                phase = .available(release, asset)
                if autoUpdate && installBlocker == nil { await download(release, asset) }
            }
        } catch {
            // Background checks stay quiet; the next scheduled check will retry.
            phase = userInitiated ? .failed("检查更新失败：\(error.localizedDescription)") : previous
        }
    }

    func download() async {
        guard case .available(let release, let asset) = phase else { return }
        await download(release, asset)
    }

    private func download(_ release: ReleaseInfo, _ asset: ReleaseAsset) async {
        if let blocker = installBlocker { phase = .failed(blocker); return }
        phase = .downloading(release)
        do {
            let staged = try await Self.prepare(asset: asset, expectedVersion: release.version, bundleID: Bundle.main.bundleIdentifier)
            phase = .ready(release, staged)
        } catch {
            phase = .failed("下载更新失败：\(error.localizedDescription)")
        }
    }

    /// Restarts into the downloaded version. Unsaved editor changes are resolved first.
    func installAndRelaunch() {
        guard case .ready(let release, let staged) = phase else { return }
        guard EditorProtection.shared.prepareForTermination() else { return }
        do {
            try launchInstaller(staged: staged, relaunch: true)
            phase = .installing
            NSApp.terminate(nil)
        } catch {
            phase = .failed("安装 \(release.displayVersion) 失败：\(error.localizedDescription)")
        }
    }

    /// With automatic updates on, a downloaded version is installed when the app quits.
    func installOnQuitIfReady() {
        guard autoUpdate, case .ready(_, let staged) = phase else { return }
        try? launchInstaller(staged: staged, relaunch: false)
    }

    func openReleasePage() {
        switch phase {
        case .available(let release, _), .manualOnly(let release), .downloading(let release), .ready(let release, _): NSWorkspace.shared.open(release.htmlURL)
        default: NSWorkspace.shared.open(AppUpdatePolicy.releasesPageURL)
        }
    }

    // MARK: - Network

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: AppUpdatePolicy.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Branchline/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError("还没有发布任何版本。") }
        if status == 403 || status == 429 { throw UpdateError("GitHub 暂时限制了访问频率，请稍后再试。") }
        guard status == 200 else { throw UpdateError("GitHub 返回状态 \(status)。") }
        return try ReleaseInfo.decoded(data)
    }

    // MARK: - Staging

    nonisolated private static var updatesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.branchline.progress", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    /// Downloads, verifies and unpacks the package, returning the staged `.app`.
    nonisolated private static func prepare(asset: ReleaseAsset, expectedVersion: AppVersion?, bundleID: String?) async throws -> URL {
        guard AppUpdatePolicy.isTrustedDownload(asset.browserDownloadURL), let format = asset.format else { throw UpdateError("安装包地址不受信任。") }
        let root = updatesDirectory
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let (temporary, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("下载未成功完成。") }
        let package = work.appendingPathComponent(asset.name)
        try fm.moveItem(at: temporary, to: package)

        let size = (try fm.attributesOfItem(atPath: package.path)[.size] as? NSNumber)?.intValue ?? -1
        guard size == asset.size else { throw UpdateError("安装包大小与发布信息不一致。") }
        if let expected = asset.sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: package, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw UpdateError("安装包校验失败（SHA-256 不一致）。") }
        }

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        switch format {
        case .zip:
            try run("/usr/bin/ditto", ["-x", "-k", package.path, unpacked.path])
        case .dmg:
            let mount = work.appendingPathComponent("mount", isDirectory: true)
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", package.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let app = findApp(in: mount) else { throw UpdateError("磁盘映像中没有找到 脉络.app。") }
            try run("/usr/bin/ditto", [app.path, unpacked.appendingPathComponent(app.lastPathComponent).path])
        }
        guard let app = findApp(in: unpacked) else { throw UpdateError("安装包中没有找到 脉络.app。") }

        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else { throw UpdateError("安装包不是脉络应用。") }
        if let expectedVersion {
            let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
            guard version == expectedVersion else { throw UpdateError("安装包版本与发布版本不一致。") }
        }
        // The release is ad-hoc signed: this confirms the bundle is intact, not who signed it.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    nonisolated private static func findApp(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // Zips made from a folder hold the app one level down.
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let app = ((try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []).first(where: { $0.pathExtension == "app" }) { return app }
        }
        return nil
    }

    @discardableResult nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) 失败：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    // MARK: - Install

    /// The helper waits for this process to exit, keeps the old bundle as a backup while copying,
    /// restores it if the copy fails, and reopens the app when asked.
    private func launchInstaller(staged: URL, relaunch: Bool) throws {
        if let blocker = installBlocker { throw UpdateError(blocker) }
        let script = """
        #!/bin/sh
        pid="$1"; target="$2"; staged="$3"; relaunch="$4"; workdir="$5"
        backup="${target%.app}.更新前备份.app"
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.2; waited=$((waited + 1))
          [ "$waited" -gt 600 ] && exit 1
        done
        rm -rf "$backup"
        if mv "$target" "$backup"; then
          if /usr/bin/ditto "$staged" "$target"; then
            rm -rf "$backup"
          else
            rm -rf "$target"; mv "$backup" "$target"
          fi
        fi
        rm -rf "$workdir"
        [ "$relaunch" = "1" ] && /usr/bin/open "$target"
        exit 0
        """
        let workdir = Self.updatesDirectory
        let scriptURL = workdir.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), bundleURL.path, staged.path, relaunch ? "1" : "0", workdir.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

struct UpdateError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }

extension ReleaseInfo { var displayVersion: String { version?.description ?? tagName } }

struct UpdateSettingsSection: View {
    @Bindable var updater: AppUpdater
    var body: some View {
        Section("软件更新") {
            LabeledContent("当前版本", value: updater.currentVersion)
            Toggle("自动更新", isOn: $updater.autoUpdate)
            Text("每天检查一次 GitHub 上的新版本并在后台下载。下载完成后可以立即重启安装，也会在退出脉络时自动安装。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("检查更新") { Task { await updater.check(userInitiated: true) } }.disabled(updater.busy)
                switch updater.phase {
                case .available:
                    if updater.installBlocker == nil { Button("下载并安装") { Task { await updater.download() } } }
                    Button("查看更新说明") { updater.openReleasePage() }
                case .manualOnly, .failed:
                    Button("打开下载页面") { updater.openReleasePage() }
                case .ready:
                    Button("立即重启并更新") { updater.installAndRelaunch() }
                    Button("查看更新说明") { updater.openReleasePage() }
                default: EmptyView()
                }
                if updater.busy { ProgressView().controlSize(.small) }
            }
            Text(updater.statusText).font(.caption).foregroundStyle(updater.phase.isFailure ? Color.red : Color.secondary).textSelection(.enabled)
            if updater.hasUpdate, let blocker = updater.installBlocker {
                Text(blocker).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

extension AppUpdater.Phase { var isFailure: Bool { if case .failed = self { true } else { false } } }
