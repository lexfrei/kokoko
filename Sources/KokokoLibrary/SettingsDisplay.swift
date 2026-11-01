import KokokoCore

extension JSONValue {
    public var displayText: String {
        switch self {
        case .int(let v): return "\(v)"
        case .double(let v): return Int(exactly: v).map(String.init) ?? "\(v)"
        case .string(let v): return v
        case .bool(let v): return v ? "on" : "off"
        case .array: return "[…]"
        case .object: return "{…}"
        case .null: return "-"
        }
    }
}
