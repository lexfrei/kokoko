/// The header's tabs. Every tab is always shown; the bin is stored on this
/// computer, so it is the only one that works without a device.
public enum HeaderTab: CaseIterable, Sendable {
    case sounds, projects, settings, bin

    public var title: String {
        switch self {
        case .sounds: "sounds"
        case .projects: "projects"
        case .settings: "settings"
        case .bin: "bin"
        }
    }

    public var needsDevice: Bool { self != .bin }

    public var readsDeviceWhenOpened: Bool { self == .projects || self == .settings }

    public func isEnabled(deviceBusy: Bool) -> Bool {
        !(deviceBusy && readsDeviceWhenOpened)
    }
}

public enum DevicePhase: Equatable, Sendable {
    case searching
    case connecting(String)
    case connected
    case failed
}

/// What a tab shows instead of its content, or nil when it can show its content.
public func tabNotice(_ tab: HeaderTab, device: DevicePhase) -> String? {
    guard tab.needsDevice else { return nil }
    switch device {
    case .connected: return nil
    case .failed: return "device not connected"
    case .searching: return "scanning for midi devices..."
    case .connecting(let name): return "connecting to \(name)..."
    }
}
