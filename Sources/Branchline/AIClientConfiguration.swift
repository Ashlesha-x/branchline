import Foundation
import ProgressCore

struct AIClientConfiguration {
    enum DesktopStatus { case missing, configured, different }

    let executable: URL
    let arguments: [String]

    init(executable: URL, dataDirectory: URL) {
        self.executable = executable
        arguments = dataDirectory.standardizedFileURL.path == LocalBridgeClient.defaultDirectory.standardizedFileURL.path
            ? ["mcp"] : ["--data-dir", dataDirectory.standardizedFileURL.path, "mcp"]
    }

    static var desktopConfigURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    static var codexConfigURL: URL {
        if let directory = ProcessInfo.processInfo.environment["CODEX_HOME"], !directory.isEmpty {
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("config.toml")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    private var entry: [String: Any] { ["command": executable.path, "args": arguments] }

    func desktopJSON() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["branchline": entry]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    var claudeCodeCommand: String {
        let command = ([executable.path] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        return "claude mcp add --transport stdio --scope user branchline -- \(command)"
    }

    func codexTOML() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let command = try String(decoding: encoder.encode(executable.path), as: UTF8.self)
        let args = try String(decoding: encoder.encode(arguments), as: UTF8.self)
        return "[mcp_servers.branchline]\ncommand = \(command)\nargs = \(args)"
    }

    func desktopStatus(at url: URL = Self.desktopConfigURL) throws -> DesktopStatus {
        let (_, _, servers) = try readDesktopConfig(at: url)
        return status(in: servers)
    }

    func addToClaudeDesktop(at url: URL = Self.desktopConfigURL) throws {
        let (original, currentConfig, currentServers) = try readDesktopConfig(at: url)
        var config = currentConfig, servers = currentServers
        switch status(in: servers) {
        case .configured: return
        case .different: throw WorkspaceError("Claude Desktop 已有一条不同的 branchline 配置，请在配置文件中核对路径和参数。")
        case .missing: break
        }
        servers["branchline"] = entry
        config["mcpServers"] = servers
        var updated = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        updated.append(0x0a)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try readDesktopConfig(at: url).0 == original else {
            throw WorkspaceError("Claude Desktop 配置刚刚发生变化，请再试一次。")
        }
        try updated.write(to: url, options: .atomic)
    }

    private func status(in servers: [String: Any]) -> DesktopStatus {
        guard let existing = servers["branchline"] else { return .missing }
        guard let existing = existing as? [String: Any],
              existing["command"] as? String == executable.path,
              existing["args"] as? [String] == arguments,
              existing["type"] == nil || existing["type"] as? String == "stdio" else { return .different }
        return .configured
    }

    private func readDesktopConfig(at url: URL) throws -> (Data?, [String: Any], [String: Any]) {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return (nil, [:], [:]) }
        guard let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WorkspaceError("Claude Desktop 配置文件不是有效的 JSON 对象，请检查后重试。")
        }
        guard let value = config["mcpServers"] else { return (data, config, [:]) }
        guard let servers = value as? [String: Any] else {
            throw WorkspaceError("Claude Desktop 配置中的 mcpServers 格式有误，请检查后重试。")
        }
        return (data, config, servers)
    }
}
