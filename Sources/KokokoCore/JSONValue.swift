import Foundation

/// JSON value used for device metadata: Sendable and Equatable, unlike [String: Any].
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
        case is NSNull: self = .null
        // JSONSerialization hands numbers and booleans back as NSNumber, and `as? Int`
        // matches true and 2.0 too, so the kind is read off the NSNumber itself.
        case let v as NSNumber where CFGetTypeID(v) == CFBooleanGetTypeID(): self = .bool(v.boolValue)
        case let v as NSNumber where ["d", "f"].contains(String(cString: v.objCType)): self = .double(v.doubleValue)
        case let v as NSNumber:
            // Past Int.max (objCType "Q") intValue would wrap to a negative number.
            if let exact = v as? Int { self = .int(exact) } else { self = .double(v.doubleValue) }
        case let v as String: self = .string(v)
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

    /// Also accepts a double with an exact integer value: JSON has no int/float
    /// distinction, so a device may send 46875 as 46875.0.
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v)
        default: return nil
        }
    }

    /// The value with every integral double turned into an int, for comparing metadata
    /// across a JSON round trip, which writes 2.0 as 2.
    public var normalizedNumbers: JSONValue {
        switch self {
        case .double(let v): return Int(exactly: v).map(JSONValue.int) ?? self
        case .array(let v): return .array(v.map(\.normalizedNumbers))
        case .object(let v): return .object(v.mapValues(\.normalizedNumbers))
        default: return self
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}
