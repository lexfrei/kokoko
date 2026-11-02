/// The header's tabs. Every tab is always shown and can always be chosen, a
/// busy device included; the bin is stored on this computer, so it is the
/// only one that works without a device.
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
}

public enum DevicePhase: Equatable, Sendable {
    case searching
    case connecting(String)
    case connected
    case failed
}

/// What a tab shows instead of its content, or nil when it can show its content.
public func tabNotice(_ tab: HeaderTab, device: DevicePhase, waitingForDevice: Bool = false) -> String? {
    guard tab.needsDevice else { return nil }
    switch device {
    case .connected: return waitingForDevice && tab.readsDeviceWhenOpened ? "device busy, loading when free" : nil
    case .failed: return "device not connected"
    case .searching: return "scanning for midi devices..."
    case .connecting(let name): return "connecting to \(name)..."
    }
}

/// A tab that reads from the device when it opens, held while the device is
/// busy, so it loads once the device is released instead of being refused.
public struct PendingTabLoad: Equatable, Sendable {
    public private(set) var waiting: HeaderTab?

    public init() {}

    /// The tab to load now, or nil when it waits for the device or has
    /// nothing to load; opening another tab ends an earlier wait. Chosen
    /// again while it is on screen and the device is busy, a tab stays as it
    /// is: still waiting if it was, and otherwise showing what it shows,
    /// since the operation holding the device may be loading it.
    public mutating func open(_ tab: HeaderTab, showing current: HeaderTab? = nil, needsLoad: Bool = true,
                              deviceBusy: Bool) -> HeaderTab? {
        if tab == current && deviceBusy { return nil }
        let loads = tab.readsDeviceWhenOpened && needsLoad
        waiting = loads && deviceBusy ? tab : nil
        return loads && !deviceBusy ? tab : nil
    }

    /// The tab to load now that the device is free: the waiting one, if it
    /// is still on screen and still has something to load, since the
    /// operation that held the device may have loaded it already.
    public mutating func deviceReleased(showing view: HeaderTab, needsLoad: Bool = true) -> HeaderTab? {
        defer { waiting = nil }
        return waiting == view && needsLoad ? waiting : nil
    }
}
