import Foundation

public struct MaterialLink: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let url: URL

    public init?(address: String, title: String = "") {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = address.hasPrefix("/") ? URL(fileURLWithPath: address) : URL(string: address)
        guard let url, Self.canOpen(url) else { return nil }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? (url.isFileURL ? url.lastPathComponent : url.host ?? address) : title
        self.url = url
    }

    public static func canOpen(_ url: URL) -> Bool {
        if url.isFileURL { return (url.host ?? "").isEmpty && url.path.hasPrefix("/") }
        return ["https", "http"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }

    var markdown: String { "[\(Self.label(title))](<\(url.absoluteString)>)" }

    static func label(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}

extension WorkRecord {
    func validateMaterials() throws {
        guard (materials ?? []).allSatisfy({ MaterialLink.canOpen($0.url) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw WorkspaceError("相关资料需要名称和有效的网页地址或本机路径。")
        }
    }
}
