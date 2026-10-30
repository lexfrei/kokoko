import Foundation

/// JSON value used for device metadata: Sendable and Codable, unlike [String: Any].
public enum JSONValue: Equatable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init?(any: Any) {
        switch any {
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as [Any]: self = .array(v.compactMap(JSONValue.init(any:)))
        case let v as [String: Any]:
            self = .object(v.compactMapValues { JSONValue(any: $0) })
        default: return nil
        }
    }

    public var anyValue: Any {
        switch self {
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        case .null: return NSNull()
        }
    }

    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}
