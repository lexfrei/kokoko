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

/// What a tab shows instead of its content, or nil when it can show its content.
public func tabNotice(_ tab: HeaderTab, connected: Bool) -> String? {
    tab.needsDevice && !connected ? "device not connected" : nil
}
