import Foundation
import ProgressCore

@MainActor func appVersionsCompareNumericallyAndRankPrereleases() throws {
    let v = { (text: String) throws -> AppVersion in try require(AppVersion(text)) }
    try expect(v("v0.15.10") > v("0.15.9"))
    try expect(v("0.16") == v("0.16.0"))
    try expect(v("1.0.0-beta.2") < v("1.0.0"))
    try expect(v("1.0.0-beta.10") > v("1.0.0-beta.2"))
    try expect(v("0.15.3").description == "0.15.3")
    try expect(AppVersion("开发版") == nil && AppVersion("") == nil && AppVersion("1..2") == nil)
}

private func release(_ tag: String, assets: [(String, Int)], prerelease: Bool = false) -> ReleaseInfo {
    ReleaseInfo(tagName: tag, htmlURL: URL(string: "https://github.com/Ashlesha-x/branchline/releases/tag/\(tag)")!, prerelease: prerelease,
                assets: assets.map { ReleaseAsset(name: $0.0, browserDownloadURL: URL(string: "https://github.com/Ashlesha-x/branchline/releases/download/\(tag)/\($0.0)")!, size: $0.1) })
}

@MainActor func updateDecisionPicksInstallablePackage() throws {
    let both = release("v0.16.0", assets: [("Branchline-0.16.0-macOS-arm64.dmg", 10), ("Branchline-0.16.0-macOS-arm64.zip", 10), ("Source.tar.gz", 5)])
    guard case .available(_, let asset) = AppUpdatePolicy.decide(current: "0.15.3", release: both) else { throw CheckFailure(description: "update not offered") }
    try expect(asset.format == .zip)
    let dmgOnly = release("v0.16.0", assets: [("Branchline-0.16.0-x86_64.zip", 10), ("脉络-0.16.0.dmg", 10)])
    guard case .available(_, let dmg) = AppUpdatePolicy.decide(current: "0.15.3", release: dmgOnly) else { throw CheckFailure(description: "dmg not offered") }
    try expect(dmg.name == "脉络-0.16.0.dmg")
    try expect(AppUpdatePolicy.decide(current: "0.16.0", release: both) == .upToDate)
    try expect(AppUpdatePolicy.decide(current: "0.17.0", release: both) == .upToDate)
    try expect(AppUpdatePolicy.decide(current: "开发版", release: both) == .upToDate)
    try expect(AppUpdatePolicy.decide(current: "0.15.3", release: release("v0.16.0-beta.1", assets: [("a.zip", 1)], prerelease: true)) == .upToDate)
    let noPackage = release("v0.16.0", assets: [("notes.txt", 3)])
    try expect(AppUpdatePolicy.decide(current: "0.15.3", release: noPackage) == .manualOnly(noPackage))
    var foreign = both; foreign.assets = [ReleaseAsset(name: "x.zip", browserDownloadURL: URL(string: "https://example.com/Ashlesha-x/branchline/releases/download/v0.16.0/x.zip")!, size: 1)]
    try expect(AppUpdatePolicy.decide(current: "0.15.3", release: foreign) == .manualOnly(foreign))
}

@MainActor func releaseJSONDecodesDigestAndTrustRules() throws {
    let json = """
    {"tag_name":"v0.16.0","name":"0.16.0","body":"notes","html_url":"https://github.com/Ashlesha-x/branchline/releases/tag/v0.16.0","draft":false,"prerelease":false,"published_at":"2026-12-01T00:00:00Z",
     "assets":[{"name":"Branchline-0.16.0-macOS-arm64.zip","size":3400000,"digest":"sha256:\(String(repeating: "ab", count: 32))",
                "browser_download_url":"https://github.com/Ashlesha-x/branchline/releases/download/v0.16.0/Branchline-0.16.0-macOS-arm64.zip","content_type":"application/zip"}]}
    """
    let info = try ReleaseInfo.decoded(Data(json.utf8))
    try expect(info.version == AppVersion("0.16.0"))
    try expect(info.installableAsset?.sha256 == String(repeating: "ab", count: 32))
    try expect(ReleaseAsset(name: "a.zip", browserDownloadURL: info.htmlURL, size: 1, digest: "md5:abc").sha256 == nil)
    try expect(AppUpdatePolicy.isTrustedDownload(URL(string: "https://github.com/ashlesha-x/Branchline/releases/download/v1/a.zip")!))
    try expect(!AppUpdatePolicy.isTrustedDownload(URL(string: "http://github.com/Ashlesha-x/branchline/releases/download/v1/a.zip")!))
    try expect(!AppUpdatePolicy.isTrustedDownload(URL(string: "https://github.com/someone/branchline/releases/download/v1/a.zip")!))
    let now = Date()
    try expect(AppUpdatePolicy.isDue(lastCheck: nil, now: now))
    try expect(!AppUpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
    try expect(AppUpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
    try expect(AppUpdatePolicy.isDue(lastCheck: now.addingTimeInterval(86400), now: now))
    try expect(AppUpdatePolicy.installBlocker(bundlePath: "/Applications/脉络.app", parentWritable: true) == nil)
    try expect(AppUpdatePolicy.installBlocker(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/脉络.app", parentWritable: true) != nil)
    try expect(AppUpdatePolicy.installBlocker(bundlePath: "/Applications/脉络.app", parentWritable: false) != nil)
}
