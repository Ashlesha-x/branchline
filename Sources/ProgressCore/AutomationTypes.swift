import Foundation
import CryptoKit

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value)) }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try Self.decoder.decode(type, from: Self.encoder.encode(self)) }
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    public static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    public var digest: String { (try? Self.encoder.encode(self)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "" }
}

public struct OperationReceipt: Codable, Equatable, Sendable {
    public var requestID: String
    public var fingerprint: String
    public var date: Date
    public var ids: [String: String]
    public var changes: [JSONValue]
}

public struct AutomationPlan: Sendable {
    public var workspace: Workspace
    public var receipt: OperationReceipt
    public var replay: Bool
}

extension Workspace {
    public var automationRevision: String { (try? JSONValue.from(self).digest) ?? "invalid" }
}
