import Foundation

/// What the app does about MIDI devices coming and going. Times are seconds
/// on any monotonic clock the caller picks.
public struct HotplugPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case rescanLater
        case disconnect
    }

    public let debounce: Double
    public private(set) var isConnected = false
    private var generation = 0
    private var rescanDue: Double?

    public init(debounce: Double) {
        self.debounce = debounce
    }

    /// Taken when a scan or any other device work starts; every disconnect
    /// starts a new one.
    public func currentGeneration() -> Int { generation }

    /// Whether work that took `token` still belongs to the current device:
    /// false once a disconnect happened since, so its results are stale.
    public func isCurrent(_ token: Int) -> Bool { token == generation }

    /// A scan found a device. It is accepted only if no disconnect happened
    /// since the scan took its token, so a scan that outlived its device
    /// cannot bring back a stale connection.
    public mutating func commitConnection(token: Int) -> Bool {
        guard token == generation else { return false }
        isConnected = true
        rescanDue = nil
        return true
    }

    /// CoreMIDI reported a change. `pairOnline` says whether the connected
    /// pair is still listed and online; it is ignored while unconnected.
    public mutating func changed(now: Double, pairOnline: Bool) -> Action {
        if isConnected {
            guard !pairOnline else { return .none }
            isConnected = false
            generation += 1
            rescanDue = now + debounce
            return .disconnect
        }
        rescanDue = now + debounce
        return .rescanLater
    }

    /// Whether to start the pending rescan now: the last change is a full
    /// debounce old and no operation holds the device.
    public mutating func takeRescan(now: Double, busy: Bool) -> Bool {
        guard !isConnected, !busy, let due = rescanDue, now >= due else { return false }
        rescanDue = nil
        return true
    }
}
