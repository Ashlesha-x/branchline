import Foundation

/// Dotted numeric version such as `0.16.0`, optionally with a pre-release suffix (`0.16.0-beta.1`).
/// A leading `v` from a Git tag is accepted.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        var numbers: [Int] = []
        for piece in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(piece), number >= 0 else { return nil }
            numbers.append(number)
        }
        components = numbers
        prerelease = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
    }

    public var description: String { components.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = components; while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed); hasher.combine(prerelease)
    }
}

public struct ReleaseAsset: Decodable, Equatable, Sendable {
    public var name: String
    public var browserDownloadURL: URL
    public var size: Int
    /// GitHub publishes `sha256:<hex>` for uploaded assets.
    public var digest: String?

    public init(name: String, browserDownloadURL: URL, size: Int, digest: String? = nil) {
        self.name = name; self.browserDownloadURL = browserDownloadURL; self.size = size; self.digest = digest
    }

    enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url", size, digest }

    public var sha256: String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? String(hex) : nil
    }

    public enum Format: Sendable { case zip, dmg }
    public var format: Format? {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        if lower.hasSuffix(".dmg") { return .dmg }
        return nil
    }
}

public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public var tagName: String
    public var name: String?
    public var body: String?
    public var htmlURL: URL
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [ReleaseAsset]

    public init(tagName: String, name: String? = nil, body: String? = nil, htmlURL: URL, draft: Bool = false, prerelease: Bool = false, assets: [ReleaseAsset]) {
        self.tagName = tagName; self.name = name; self.body = body; self.htmlURL = htmlURL; self.draft = draft; self.prerelease = prerelease; self.assets = assets
    }

    enum CodingKeys: String, CodingKey { case tagName = "tag_name", name, body, htmlURL = "html_url", draft, prerelease, assets }

    public static func decoded(_ data: Data) throws -> ReleaseInfo { try JSONDecoder().decode(ReleaseInfo.self, from: data) }

    public var version: AppVersion? { AppVersion(tagName) }

    /// The package the updater can install on an Apple Silicon Mac: a zip is preferred over a dmg,
    /// and packages built only for Intel are skipped.
    public var installableAsset: ReleaseAsset? {
        let candidates = assets.filter { asset in
            let lower = asset.name.lowercased()
            guard asset.format != nil, asset.size > 0 else { return false }
            return !(lower.contains("x86_64") || lower.contains("x86-64") || lower.contains("intel"))
        }
        func rank(_ asset: ReleaseAsset) -> Int {
            let lower = asset.name.lowercased()
            let arch = lower.contains("arm64") || lower.contains("universal") ? 0 : 1
            let format = asset.format == .zip ? 0 : 1
            return arch * 2 + format
        }
        return candidates.min { rank($0) < rank($1) }
    }
}

public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available(ReleaseInfo, ReleaseAsset)
    /// A newer release exists but has no package this Mac can install automatically.
    case manualOnly(ReleaseInfo)
}

public enum AppUpdatePolicy {
    public static let owner = "Ashlesha-x"
    public static let repository = "branchline"
    public static let checkInterval: TimeInterval = 24 * 3600
    public static var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")! }
    public static var releasesPageURL: URL { URL(string: "https://github.com/\(owner)/\(repository)/releases/latest")! }

    public static func decide(current: String, release: ReleaseInfo) -> UpdateDecision {
        guard !release.draft, !release.prerelease, let latest = release.version else { return .upToDate }
        // A development build without a readable version never offers updates.
        guard let installed = AppVersion(current), installed < latest else { return .upToDate }
        guard let asset = release.installableAsset, isTrustedDownload(asset.browserDownloadURL) else { return .manualOnly(release) }
        return .available(release, asset)
    }

    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        // A clock moved backwards should not block checks until it catches up.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now.addingTimeInterval(60)
    }

    /// Only packages attached to this repository's GitHub releases are downloaded.
    public static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com" else { return false }
        let path = url.path.lowercased()
        return path.hasPrefix("/\(owner.lowercased())/\(repository.lowercased())/releases/download/") && !path.contains("/../")
    }

    /// Updating in place needs a writable folder and a real location; an app opened from a
    /// quarantined download runs from a read-only translocated copy.
    public static func installBlocker(bundlePath: String, parentWritable: Bool) -> String? {
        if bundlePath.contains("/AppTranslocation/") { return "脉络正从系统的临时隔离位置运行。请先把 脉络.app 移到“应用程序”文件夹再打开，之后即可自动更新。" }
        if bundlePath.hasPrefix("/Volumes/") { return "脉络正从磁盘映像中运行。请先把 脉络.app 复制到“应用程序”文件夹。" }
        if !parentWritable { return "没有权限替换当前位置的 脉络.app，请到下载页面手动更新。" }
        return nil
    }
}

/// Which onboarding stops a launch should show. A new user gets the full tour elsewhere and
/// only has the current version recorded; a returning user sees just the stops introduced after
/// the version they last saw (`fallbackSeen` when they used the app before tours existed).
public enum OnboardingPlan {
    public static func stopsToShow<Stop>(_ stops: [(stop: Stop, introduced: String)], seen: String?, returningUser: Bool, current: String, fallbackSeen: String = "0.17.0") -> [Stop] {
        guard let currentVersion = AppVersion(current) else { return [] }
        guard let seenText = seen ?? (returningUser ? fallbackSeen : nil), let seenVersion = AppVersion(seenText) else { return [] }
        return stops.filter { item in
            guard let introduced = AppVersion(item.introduced) else { return false }
            return seenVersion < introduced && !(currentVersion < introduced)
        }.map(\.stop)
    }
}
