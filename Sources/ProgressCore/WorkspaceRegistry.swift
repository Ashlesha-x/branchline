import Foundation

/// The list of user workspaces in one data directory. The entry with id "default" is the
/// original personal space, whose files live directly in the data directory.
public struct WorkspaceEntry: Codable, Equatable, Identifiable, Sendable {
    public static let defaultID = "default"
    public var id: String
    public var name: String
    public var createdAt: Date
    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) { self.id = id; self.name = name; self.createdAt = createdAt }
    public var isDefault: Bool { id == Self.defaultID }
}

public struct WorkspaceRegistry: Codable, Equatable, Sendable {
    public var entries: [WorkspaceEntry]
    public init(entries: [WorkspaceEntry] = [WorkspaceEntry(id: WorkspaceEntry.defaultID, name: "个人空间", createdAt: Date(timeIntervalSince1970: 0))]) { self.entries = entries }

    public func entry(_ id: String) -> WorkspaceEntry? { entries.first { $0.id == id } }

    public static func cleanName(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func validate(_ name: String, excluding id: String? = nil) throws -> String {
        let name = Self.cleanName(name)
        guard !name.isEmpty else { throw WorkspaceError("请填写工作区名称。") }
        guard name.count <= 40 else { throw WorkspaceError("工作区名称请控制在 40 个字以内。") }
        guard name != "示例空间" else { throw WorkspaceError("「示例空间」是保留名称，请换一个。") }
        guard !entries.contains(where: { $0.id != id && $0.name == name }) else { throw WorkspaceError("已有同名工作区。") }
        return name
    }
    @discardableResult public mutating func add(name: String, now: Date = Date()) throws -> WorkspaceEntry {
        let entry = WorkspaceEntry(name: try validate(name), createdAt: now)
        entries.append(entry); return entry
    }
    public mutating func rename(_ id: String, to name: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw WorkspaceError("工作区已不存在。") }
        entries[index].name = try validate(name, excluding: id)
    }
    /// Deleting needs the exact name typed back, and never removes the open or the last workspace.
    public mutating func remove(_ id: String, active: String, confirmation: String) throws -> WorkspaceEntry {
        guard let entry = entry(id) else { throw WorkspaceError("工作区已不存在。") }
        guard id != active else { throw WorkspaceError("不能删除正在使用的工作区，请先切换到其他工作区。") }
        guard entries.count > 1 else { throw WorkspaceError("至少要保留一个工作区。") }
        guard Self.cleanName(confirmation) == entry.name else { throw WorkspaceError("输入的名称与工作区名称不一致。") }
        entries.removeAll { $0.id == id }
        return entry
    }
}
