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

public enum SettingsStatus: Equatable, Sendable {
    case notLoaded, loaded, unsupported, failed

    /// A failed read waits for the retry button rather than repeating on every visit.
    public var loadsWhenOpened: Bool { self == .notLoaded }

    /// What the settings tab shows in place of the settings, or nil when it shows them.
    public func placeholder(isEmpty: Bool) -> String? {
        switch self {
        case .notLoaded: "loading..."
        case .failed: "could not read the settings"
        case .unsupported: "not exposed over midi on this firmware"
        case .loaded: isEmpty ? "no settings" : nil
        }
    }
}
